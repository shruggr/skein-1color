import { describe, expect, it } from "vitest";
import { whereOf } from "../src/where";

describe("whereOf", () => {
  it("an instance origin", () => {
    expect(whereOf("https://alice.skein.nexus/amm/color/tokens/")).toEqual({ base: "https://alice.skein.nexus", app: "amm", page: "tokens" });
  });
  it("a host's dev form, /@<handle>", () => {
    expect(whereOf("http://127.0.0.1:8100/@alice/amm/color/deploy/index.html")).toEqual({ base: "http://127.0.0.1:8100/@alice", app: "amm", page: "deploy" });
  });
  it("any app name, the 1Color app's own included", () => {
    expect(whereOf("http://a.localhost:8100/1color/color/tokens")?.app).toBe("1color");
    expect(whereOf("http://a.localhost:8100/my-amm/color/deploy/")?.app).toBe("my-amm");
  });
  it("no app, no page", () => {
    expect(whereOf("http://a.localhost:8100/color/tokens/")).toBeUndefined();
    expect(whereOf("http://a.localhost:8100/amm/color/other/")).toBeUndefined();
    expect(whereOf("http://a.localhost:8100/")).toBeUndefined();
  });
});
