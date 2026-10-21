// The request root's message is: skein's RawBox.send, its body as the
// front door reads it (BRC-231 CBOR {message: {recipient, messageBox, body}}),
// captured below the BRC-104 layer by stubbing the session.
import { describe, expect, it } from "vitest";
import "../src/shims";
import * as dagCbor from "@ipld/dag-cbor";
import { PrivateKey, ProtoWallet, type WalletInterface } from "@bsv/sdk";
import { Instance } from "../src/tokens/instance";
import { register } from "../src/tokens/list";

describe("root's message", () => {
  it("POST <base>/sendMessage to the app's box, the call as the body", async () => {
    const wallet = new ProtoWallet(PrivateKey.fromHex("02".repeat(32))) as unknown as WalletInterface;
    const inst = new Instance(wallet, "http://127.0.0.1:8100/@alice");
    const identity = PrivateKey.fromHex("03".repeat(32)).toPublicKey().toString();
    inst.answeredBy = identity;
    const sent: Array<{ url: string; init: { method: string; headers: Record<string, string>; body: Uint8Array } }> = [];
    const box = inst.box as unknown as { ensurePeer: () => Promise<void>; af: { fetch: (u: string, i: never) => Promise<Response> } };
    box.ensurePeer = async () => {};
    box.af.fetch = async (url: string, init: never) => {
      sent.push({ url, init });
      return new Response(dagCbor.encode({ status: "success", id: "bafyreigh2akiscaildcqabsyg3dfr6chu3fgpregiymsck7e7aqa4s52zy" }) as unknown as BodyInit, { status: 200 });
    };
    const id = await inst.send("amm/register", register(`tm_color_${"ef".repeat(32)}_0`));
    expect(id).toBe("bafyreigh2akiscaildcqabsyg3dfr6chu3fgpregiymsck7e7aqa4s52zy");
    expect(sent).toHaveLength(1);
    expect(sent[0]!.url).toBe("http://127.0.0.1:8100/@alice/sendMessage");
    expect(sent[0]!.init.headers["content-type"]).toBe("application/cbor");
    const m = (dagCbor.decode(sent[0]!.init.body) as { message: { recipient: Uint8Array; messageBox: string; body: Uint8Array } }).message;
    expect(Buffer.from(m.recipient).toString("hex")).toBe(identity);
    expect(m.messageBox).toBe("amm/register");
    expect(dagCbor.decode(m.body)).toEqual({ fn: "register", args: { topic: `tm_color_${"ef".repeat(32)}_0`, program: "color-topic", seed: ["ef".repeat(32)] } });
  });
});
