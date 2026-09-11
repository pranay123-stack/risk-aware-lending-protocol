"use client";

import { protocolErrorsAbi } from "@lending/shared";
import { useQueryClient } from "@tanstack/react-query";
import { createContext, useCallback, useContext, useState, type ReactNode } from "react";
import type { Abi, Address } from "viem";
import { useAccount, usePublicClient, useWalletClient } from "wagmi";
import { explainError } from "./errors";

// ------------------------------------------------------------------ toasts

export interface Toast {
  id: number;
  tone: "success" | "error" | "info";
  title: string;
  body?: string;
}

const ToastContext = createContext<{ toasts: Toast[]; push: (t: Omit<Toast, "id">) => void; dismiss: (id: number) => void } | null>(null);

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const dismiss = useCallback((id: number) => setToasts((t) => t.filter((x) => x.id !== id)), []);
  const push = useCallback(
    (t: Omit<Toast, "id">) => {
      const id = Date.now() + Math.random();
      setToasts((all) => [...all.slice(-3), { ...t, id }]);
      setTimeout(() => dismiss(id), t.tone === "error" ? 9_000 : 5_000);
    },
    [dismiss],
  );
  return <ToastContext.Provider value={{ toasts, push, dismiss }}>{children}</ToastContext.Provider>;
}

export function useToasts() {
  const ctx = useContext(ToastContext);
  if (!ctx) throw new Error("useToasts outside ToastProvider");
  return ctx;
}

// ------------------------------------------------------------------ transactions

export interface TxStep {
  label: string;
  address: Address;
  abi: Abi | readonly unknown[];
  functionName: string;
  args?: readonly unknown[];
}

export interface TxState {
  busy: boolean;
  step: string | null;
  error: string | null;
}

/**
 * Runs a sequence of contract calls (e.g. approve then supply). Every step is SIMULATED first, so
 * a revert is explained in plain language before the user is asked to sign anything. The
 * protocol's full error ABI is attached so custom errors from linked libraries decode too.
 */
export function useTransactor() {
  const { address } = useAccount();
  const publicClient = usePublicClient();
  const { data: walletClient } = useWalletClient();
  const queryClient = useQueryClient();
  const { push } = useToasts();
  const [state, setState] = useState<TxState>({ busy: false, step: null, error: null });

  const run = useCallback(
    async (steps: TxStep[], success: string): Promise<boolean> => {
      if (!address || !walletClient || !publicClient) {
        setState({ busy: false, step: null, error: "Connect a wallet first." });
        return false;
      }
      try {
        for (const step of steps) {
          setState({ busy: true, step: step.label, error: null });
          const abi = [...(step.abi as Abi), ...(protocolErrorsAbi as Abi)] as Abi;
          const { request } = await publicClient.simulateContract({
            account: address,
            address: step.address,
            abi,
            functionName: step.functionName,
            args: step.args ?? [],
          } as never);
          const hash = await walletClient.writeContract(request as never);
          const receipt = await publicClient.waitForTransactionReceipt({ hash });
          if (receipt.status !== "success") throw new Error(`${step.label} reverted`);
        }
        setState({ busy: false, step: null, error: null });
        push({ tone: "success", title: success });
        await queryClient.invalidateQueries();
        return true;
      } catch (err) {
        const message = explainError(err);
        setState({ busy: false, step: null, error: message });
        push({ tone: "error", title: "Transaction not sent", body: message });
        return false;
      }
    },
    [address, walletClient, publicClient, push, queryClient],
  );

  const reset = useCallback(() => setState({ busy: false, step: null, error: null }), []);
  return { ...state, run, reset };
}
