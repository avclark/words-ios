// Words — send-push edge function (Phase 10).
//
// Drains notification_outbox to APNs. Deliberately takes NO payload input:
// invoking it (from pg_net, cron, or anyone) can only deliver rows that
// legitimate game events already queued — there is no way to inject
// content through this function, which is part of the no-nags guarantee.
//
// Deploy:  supabase functions deploy send-push --no-verify-jwt
// Secrets: APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY (p8 file contents),
//          APNS_TOPIC (bundle id), APNS_ENV ("sandbox" | "production")

import { createClient } from "npm:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const APNS_HOST = Deno.env.get("APNS_ENV") === "production"
  ? "https://api.push.apple.com"
  : "https://api.sandbox.push.apple.com";

// APNs provider JWTs are valid 20–60 min; cache and refresh at 40.
let cachedJWT: { token: string; issuedAt: number } | null = null;

async function apnsJWT(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJWT && now - cachedJWT.issuedAt < 40 * 60) return cachedJWT.token;

  const keyID = Deno.env.get("APNS_KEY_ID")!;
  const teamID = Deno.env.get("APNS_TEAM_ID")!;
  const pem = Deno.env.get("APNS_PRIVATE_KEY")!;

  const der = Uint8Array.from(
    atob(pem.replace(/-----[^-]+-----/g, "").replace(/\s/g, "")),
    (c) => c.charCodeAt(0),
  );
  const key = await crypto.subtle.importKey(
    "pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
  );

  const b64url = (data: Uint8Array | string) => {
    const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
    return btoa(String.fromCharCode(...bytes))
      .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  };
  const header = b64url(JSON.stringify({ alg: "ES256", kid: keyID }));
  const claims = b64url(JSON.stringify({ iss: teamID, iat: now }));
  const signature = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(`${header}.${claims}`),
  ));
  const token = `${header}.${claims}.${b64url(signature)}`;
  cachedJWT = { token, issuedAt: now };
  return token;
}

interface OutboxRow {
  id: number;
  recipient: string;
  type: string;
  game_id: string | null;
  title: string;
  body: string;
  badge: number | null;
}

async function sendToDevice(token: string, row: OutboxRow): Promise<
  { ok: true } | { ok: false; status: number; reason: string }
> {
  const response = await fetch(`${APNS_HOST}/3/device/${token}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${await apnsJWT()}`,
      "apns-topic": Deno.env.get("APNS_TOPIC")!,
      "apns-push-type": "alert",
      "apns-priority": "10",
    },
    body: JSON.stringify({
      aps: {
        alert: { title: row.title, body: row.body },
        ...(row.badge !== null ? { badge: row.badge } : {}),
        sound: "default",
      },
      game_id: row.game_id,
      type: row.type,
    }),
  });
  if (response.ok) return { ok: true };
  let reason = "";
  try {
    reason = (await response.json())?.reason ?? "";
  } catch (_) { /* empty body */ }
  return { ok: false, status: response.status, reason };
}

Deno.serve(async (_req) => {
  // Claim-first so concurrent invocations can't double-send a row.
  const { data: pending, error } = await supabase
    .from("notification_outbox")
    .select("id, recipient, type, game_id, title, body, badge")
    .is("sent_at", null)
    .is("error", null)
    .order("id")
    .limit(50);
  if (error) return Response.json({ error: error.message }, { status: 500 });

  let delivered = 0, dropped = 0;
  for (const row of (pending ?? []) as OutboxRow[]) {
    const { data: claimed } = await supabase
      .from("notification_outbox")
      .update({ sent_at: new Date().toISOString() })
      .eq("id", row.id)
      .is("sent_at", null)
      .select("id");
    if (!claimed || claimed.length === 0) continue;  // another invocation has it

    const { data: tokens } = await supabase
      .from("device_tokens")
      .select("token")
      .eq("user_id", row.recipient);

    if (!tokens || tokens.length === 0) {
      await supabase.from("notification_outbox")
        .update({ error: "no_device_tokens" }).eq("id", row.id);
      dropped++;
      continue;
    }

    const failures: string[] = [];
    for (const { token } of tokens) {
      const result = await sendToDevice(token, row);
      if (result.ok) {
        delivered++;
      } else if (
        result.status === 410 || result.reason === "BadDeviceToken" ||
        result.reason === "Unregistered"
      ) {
        // Token invalidated (app deleted, etc.) — forget it.
        await supabase.from("device_tokens").delete().eq("token", token);
        failures.push(`${result.status}:${result.reason}`);
      } else {
        failures.push(`${result.status}:${result.reason}`);
      }
    }
    if (failures.length === tokens.length) {
      await supabase.from("notification_outbox")
        .update({ error: failures.join(",").slice(0, 200) }).eq("id", row.id);
      dropped++;
    }
  }
  return Response.json({ processed: (pending ?? []).length, delivered, dropped });
});
