import { MAX_UINT256, toNumber, wadToNumber } from "@lending/shared";
import type { FastifyInstance } from "fastify";
import type { Address } from "viem";
import type { AppContext } from "../context.js";
import { healthDto, positionsDto } from "../dto.js";
import { HttpError, parseAddress, parseLimit, parseOffset } from "../http.js";

const PREVIEW_STATUS = ["OK", "NOTHING_TO_LIQUIDATE", "LEAVES_DUST"] as const;

export function registerLiquidationRoutes(app: FastifyInstance, ctx: AppContext) {
  /**
   * Executed liquidations with USD values at the time of liquidation: each leg is priced with the
   * last primary-feed answer at or before the liquidation block (from indexed feed events).
   */
  app.get<{ Querystring: { limit?: string; offset?: string; borrower?: string; liquidator?: string } }>(
    "/liquidations",
    async (req) => {
      const limit = parseLimit(req.query.limit);
      const offset = parseOffset(req.query.offset);
      const borrower = req.query.borrower ? parseAddress(req.query.borrower, "borrower").toLowerCase() : null;
      const liquidator = req.query.liquidator ? parseAddress(req.query.liquidator, "liquidator").toLowerCase() : null;

      const res = await ctx.db.query(
        `SELECT l.tx_hash, l.log_index, l.block_number, l.block_time, l.collateral_asset, l.debt_asset,
                l.borrower, l.liquidator, l.debt_repaid::text, l.collateral_seized::text, l.receive_supply,
                (SELECT answer::text FROM price_updates p WHERE p.asset = l.debt_asset AND p.feed_role = 'primary'
                   AND p.block_number <= l.block_number ORDER BY p.block_number DESC, p.log_index DESC LIMIT 1) AS debt_price,
                (SELECT answer::text FROM price_updates p WHERE p.asset = l.collateral_asset AND p.feed_role = 'primary'
                   AND p.block_number <= l.block_number ORDER BY p.block_number DESC, p.log_index DESC LIMIT 1) AS collateral_price
         FROM liquidations l
         WHERE ($1::text IS NULL OR l.borrower = $1) AND ($2::text IS NULL OR l.liquidator = $2)
         ORDER BY l.block_number DESC, l.log_index DESC
         LIMIT $3 OFFSET $4`,
        [borrower, liquidator, limit, offset],
      );
      const total = await ctx.db.query(
        `SELECT count(*)::int AS n FROM liquidations WHERE ($1::text IS NULL OR borrower = $1) AND ($2::text IS NULL OR liquidator = $2)`,
        [borrower, liquidator],
      );

      const meta = await assetMeta(ctx);
      const rows = res.rows.map((r) => {
        const debt = meta.get(r.debt_asset);
        const coll = meta.get(r.collateral_asset);
        const repaid = BigInt(r.debt_repaid);
        const seized = BigInt(r.collateral_seized);
        const debtUsd = debt && r.debt_price ? toNumber(repaid, debt.decimals) * toNumber(BigInt(r.debt_price), debt.feedDecimals) : null;
        const collUsd = coll && r.collateral_price ? toNumber(seized, coll.decimals) * toNumber(BigInt(r.collateral_price), coll.feedDecimals) : null;
        return {
          txHash: r.tx_hash,
          logIndex: r.log_index,
          blockNumber: r.block_number,
          blockTime: r.block_time,
          borrower: r.borrower,
          liquidator: r.liquidator,
          receiveSupply: r.receive_supply,
          debt: { asset: r.debt_asset, symbol: debt?.symbol ?? "?", raw: r.debt_repaid, amount: debt ? toNumber(repaid, debt.decimals) : null, usd: debtUsd },
          collateral: { asset: r.collateral_asset, symbol: coll?.symbol ?? "?", raw: r.collateral_seized, amount: coll ? toNumber(seized, coll.decimals) : null, usd: collUsd },
          liquidatorProfitUsd: debtUsd !== null && collUsd !== null ? collUsd - debtUsd : null,
        };
      });
      return { total: total.rows[0].n, liquidations: rows };
    },
  );

  /** What a liquidation would do right now: the pool's own amount maths via PoolLens. */
  app.get<{ Querystring: { borrower?: string; collateral?: string; debt?: string; amount?: string } }>(
    "/liquidations/preview",
    async (req) => {
      const borrower = parseAddress(req.query.borrower, "borrower");
      const collateral = parseAddress(req.query.collateral, "collateral");
      const debt = parseAddress(req.query.debt, "debt");
      let amount = MAX_UINT256;
      if (req.query.amount !== undefined) {
        if (!/^\d+$/.test(req.query.amount)) throw new HttpError(400, "INVALID_AMOUNT", "amount must be an integer in token units");
        amount = BigInt(req.query.amount);
      }
      const p = await ctx.reader.previewLiquidation(borrower, collateral, debt, amount);
      return {
        borrower,
        collateral,
        debt,
        liquidatable: p.liquidatable,
        status: PREVIEW_STATUS[p.status] ?? "UNKNOWN",
        healthFactorRaw: p.healthFactor.toString(),
        closeFactor: Number(p.closeFactor) / 10_000,
        debtRepaidRaw: p.debtRepaid.toString(),
        collateralSeizedRaw: p.collateralSeized.toString(),
        debtRepaidUsd: wadToNumber(p.debtRepaidValue),
        collateralSeizedUsd: wadToNumber(p.collateralSeizedValue),
        profitUsd: wadToNumber(p.collateralSeizedValue) - wadToNumber(p.debtRepaidValue),
      };
    },
  );

  /**
   * Accounts the monitor last saw as liquidatable, re-checked live, each with the most profitable
   * single (collateral, debt) pair a liquidator could take right now.
   */
  app.get<{ Querystring: { limit?: string } }>("/liquidations/candidates", async (req) => {
    const limit = parseLimit(req.query.limit, 20, 100);
    const res = await ctx.db.query(
      `SELECT account FROM account_risk_latest WHERE level IN ('LIQUIDATABLE', 'DANGER')
       ORDER BY health_factor ASC NULLS LAST LIMIT $1`,
      [limit],
    );
    const markets = await ctx.reader.markets();
    const out = [];
    for (const { account } of res.rows as { account: string }[]) {
      const address = parseAddress(account);
      const p = await ctx.reader.userPositions(address);
      const health = healthDto(address, p[1]);
      const positions = positionsDto(p, markets);
      const debts = positions.filter((x) => x.borrowed.raw !== "0");
      const collaterals = positions.filter((x) => x.collateralEnabled && x.supplied.raw !== "0");
      // The sweep can be up to one interval old. An account whose debt has since been repaid or
      // liquidated away is not a candidate by any definition (its health factor is infinite), and
      // listing it puts a "$0.00 / $0.00" row in front of liquidators.
      if (debts.length === 0) continue;
      let best: Record<string, unknown> | null = null;
      if (health.riskLevel === "LIQUIDATABLE") {
        for (const d of debts) {
          for (const c of collaterals) {
            const pr = await ctx.reader.previewLiquidation(address, c.asset as Address, d.asset as Address, MAX_UINT256);
            if (!pr.liquidatable) continue;
            const profit = wadToNumber(pr.collateralSeizedValue) - wadToNumber(pr.debtRepaidValue);
            if (!best || profit > (best.profitUsd as number)) {
              best = {
                collateralAsset: c.asset,
                collateralSymbol: c.symbol,
                debtAsset: d.asset,
                debtSymbol: d.symbol,
                debtToCoverRaw: pr.debtRepaid.toString(),
                debtToCover: toNumber(pr.debtRepaid, d.decimals),
                collateralSeized: toNumber(pr.collateralSeized, c.decimals),
                closeFactor: Number(pr.closeFactor) / 10_000,
                profitUsd: profit,
              };
            }
          }
        }
      }
      out.push({ ...health, positions: [...debts, ...collaterals.filter((c) => !debts.includes(c))], bestLiquidation: best });
    }
    return { candidates: out };
  });
}

interface AssetMeta {
  symbol: string;
  decimals: number;
  feedDecimals: number;
}

async function assetMeta(ctx: AppContext): Promise<Map<string, AssetMeta>> {
  const [markets, oracles] = await Promise.all([ctx.reader.markets(), ctx.reader.oracles()]);
  const feedDecimals = new Map(oracles.map((o) => [o.asset.toLowerCase(), Number(o.config.primaryDecimals)]));
  return new Map(
    markets.map((m) => [
      m.asset.toLowerCase(),
      { symbol: m.symbol, decimals: Number(m.decimals), feedDecimals: feedDecimals.get(m.asset.toLowerCase()) ?? 8 },
    ]),
  );
}
