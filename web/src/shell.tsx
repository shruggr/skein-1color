/**
 * What both pages share: the wallet (@1sat/react over @1sat/connect, as the
 * AMM pages connect it), the header, the mount.
 */
import "./shims";
import { StrictMode, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import { ConnectButton, ConnectDialogProvider, WalletProvider, useWallet } from "@1sat/react";
import { whereOf } from "./where";
import "./style.css";

export const short = (k: string) => (k.length > 16 ? `${k.slice(0, 8)}…${k.slice(-6)}` : k);

function Who() {
  const { identityKey, status } = useWallet();
  return (
    <span className="mut small">
      {status === "connected" && identityKey ? <>wallet <code title={identityKey}>{short(identityKey)}</code></> : "no wallet connected"}
    </span>
  );
}

export function mount(title: string, page: ReactNode) {
  const where = whereOf(location.href);
  const root = document.getElementById("root");
  if (!root) throw new Error("missing #root");
  document.title = `${title} · 1Color`;
  createRoot(root).render(
    <StrictMode>
      <WalletProvider autoDetect autoReconnect>
        <ConnectDialogProvider>
          <header className="top">
            <span className="home">1Color{where ? <span className="mut"> · {where.app}</span> : null}</span>
            <a href="../deploy/">Deploy a token</a>
            <a href="../tokens/">Tokens on this overlay</a>
            <Who />
            <ConnectButton />
          </header>
          <main>{page}</main>
        </ConnectDialogProvider>
      </WalletProvider>
    </StrictMode>,
  );
}
