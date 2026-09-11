"use client";

import { keepPreviousData, useQuery } from "@tanstack/react-query";
import type { Address } from "viem";
import {
  api,
  type Account,
  type Alert,
  type Analytics,
  type Candidate,
  type ChainEvent,
  type DeploymentConfig,
  type Liquidation,
  type Market,
  type MarketDetail,
  type MarketRisk,
  type OracleAsset,
  type ProtocolStatus,
  type ProtocolTvl,
  type RiskAccount,
  type RiskSummary,
  type SystemHealth,
  type TimelockOp,
} from "./api";

// Refetch quietly: previous data stays on screen (no skeleton flash), and the WebSocket
// invalidates these keys the moment the indexer or monitor commits something new.
const live = { placeholderData: keepPreviousData, refetchInterval: 15_000 } as const;

/**
 * Account-scoped queries keep previous data only for the SAME account. keepPreviousData across a
 * key change would show the previous wallet's health factor after switching accounts.
 */
const sameAccount = <T,>(address?: Address) => ({
  placeholderData: (prev: T | undefined, prevQuery?: { queryKey: readonly unknown[] }) =>
    prevQuery?.queryKey[1] === address ? prev : undefined,
  refetchInterval: 15_000,
});

export const useConfig = () => useQuery({ queryKey: ["config"], queryFn: () => api<DeploymentConfig>("/config"), staleTime: Infinity, retry: 1 });
export const useSystemHealth = () => useQuery({ queryKey: ["health"], queryFn: () => api<SystemHealth>("/health"), refetchInterval: 5_000, retry: 0 });
export const useMarkets = () => useQuery({ queryKey: ["markets"], queryFn: async () => (await api<{ markets: Market[] }>("/markets")).markets, ...live });
export const useMarket = (asset: string) =>
  useQuery({ queryKey: ["markets", asset], queryFn: () => api<MarketDetail>(`/markets/${asset}`), ...live });
export const useTvl = () => useQuery({ queryKey: ["protocol", "tvl"], queryFn: () => api<ProtocolTvl>("/protocol/tvl"), ...live });
export const useProtocolStatus = () => useQuery({ queryKey: ["protocol", "status"], queryFn: () => api<ProtocolStatus>("/protocol/status"), ...live });

export const useAccount = (address?: Address) =>
  useQuery({
    queryKey: ["account", address],
    queryFn: () => api<Account>(`/accounts/${address}`),
    enabled: Boolean(address),
    ...sameAccount<Account>(address),
  });

export const useAccountPositions = (address?: Address) =>
  useQuery({
    queryKey: ["account", address, "positions"],
    queryFn: () => api<{ positions: Account["positions"] }>(`/accounts/${address}/positions`),
    enabled: Boolean(address),
    ...sameAccount<{ positions: Account["positions"] }>(address),
  });

export const useAccountHistory = (address?: Address) =>
  useQuery({
    queryKey: ["account", address, "history"],
    queryFn: async () => (await api<{ events: ChainEvent[] }>(`/accounts/${address}/history?limit=50`)).events,
    enabled: Boolean(address),
    ...sameAccount<ChainEvent[]>(address),
  });

export const useLiquidations = () =>
  useQuery({ queryKey: ["liquidations"], queryFn: () => api<{ total: number; liquidations: Liquidation[] }>("/liquidations?limit=100"), ...live });
export const useCandidates = () =>
  useQuery({ queryKey: ["liquidations", "candidates"], queryFn: async () => (await api<{ candidates: Candidate[] }>("/liquidations/candidates")).candidates, ...live });

export const useRiskSummary = () => useQuery({ queryKey: ["risk", "summary"], queryFn: () => api<RiskSummary>("/risk/summary"), ...live });
export const useRiskAccounts = () =>
  useQuery({ queryKey: ["risk", "accounts"], queryFn: async () => (await api<{ accounts: RiskAccount[] }>("/risk/accounts")).accounts, ...live });
export const useAlerts = (status: "open" | "resolved" | "all" = "open") =>
  useQuery({ queryKey: ["risk", "alerts", status], queryFn: async () => (await api<{ alerts: Alert[] }>(`/risk/alerts?status=${status}`)).alerts, ...live });
export const useMarketRisk = () =>
  useQuery({ queryKey: ["risk", "markets"], queryFn: async () => (await api<{ markets: MarketRisk[] }>("/risk/markets")).markets, ...live });

export const useOracle = () =>
  useQuery({ queryKey: ["oracle"], queryFn: async () => (await api<{ assets: OracleAsset[]; evaluatedAt: number }>("/oracle/prices")), ...live });
export const useTimelock = () =>
  useQuery({ queryKey: ["timelock"], queryFn: () => api<{ minDelaySeconds: number; blockTimestamp: number; operations: TimelockOp[] }>("/governance/timelock"), ...live });
export const useAnalytics = (hours: number) =>
  useQuery({ queryKey: ["analytics", hours], queryFn: () => api<Analytics>(`/analytics?hours=${hours}`), ...live });
export const useEvents = (limit = 15) =>
  useQuery({ queryKey: ["events", limit], queryFn: async () => (await api<{ events: ChainEvent[] }>(`/events?limit=${limit}`)).events, ...live });
