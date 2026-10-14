// Let's Walk — sends push notifications.
// Called by database triggers (see supabase/07_push.sql), never by the app directly.
// Secrets (Supabase → Edge Functions → Secrets): VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT, NOTIFY_SECRET.
// "Verify JWT" must be OFF for this function: it checks NOTIFY_SECRET instead.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const SITE = "https://mrbokovets-debug.github.io/Let-s-Walk/";

webpush.setVapidDetails(
  Deno.env.get("VAPID_SUBJECT") ?? "mailto:hello@example.com",
  Deno.env.get("VAPID_PUBLIC_KEY")!,
  Deno.env.get("VAPID_PRIVATE_KEY")!,
);

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

const WD = ["вс", "пн", "вт", "ср", "чт", "пт", "сб"];
// Times are shown in the app's main time zone
const TZ = "Europe/Madrid";
function when(iso: string): string {
  const d = new Date(iso);
  const day = (x: Date) => new Intl.DateTimeFormat("en-CA", { timeZone: TZ }).format(x);
  const time = new Intl.DateTimeFormat("ru-RU", { timeZone: TZ, hour: "2-digit", minute: "2-digit" }).format(d);
  const today = new Date(), tomorrow = new Date(Date.now() + 86400000);
  if (day(d) === day(today)) return "сегодня в " + time;
  if (day(d) === day(tomorrow)) return "завтра в " + time;
  const en = new Intl.DateTimeFormat("en-US", { timeZone: TZ, weekday: "short" }).format(d);
  const wd = WD[["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].indexOf(en)] ?? "";
  const dm = new Intl.DateTimeFormat("ru-RU", { timeZone: TZ, day: "numeric", month: "short" }).format(d).replace(".", "");
  return (wd ? wd + ", " : "") + dm + " в " + time;
}

async function nameOf(id: string): Promise<string> {
  const { data } = await db.from("profiles").select("name").eq("id", id).maybeSingle();
  return data?.name || "Кто-то";
}

// Remove people who have hidden the sender
async function withoutBlockers(recipients: string[], sender: string): Promise<string[]> {
  if (!recipients.length) return [];
  const { data } = await db.from("blocks").select("blocker_id").eq("blocked_id", sender).in("blocker_id", recipients);
  const blockers = new Set((data ?? []).map((r) => r.blocker_id));
  return recipients.filter((id) => !blockers.has(id));
}

async function send(recipients: string[], msg: { title: string; body: string; url: string; tag: string }) {
  recipients = [...new Set(recipients)];
  if (!recipients.length) return 0;
  const { data: subs } = await db.from("push_subscriptions").select("id,endpoint,p256dh,auth").in("user_id", recipients);
  let sent = 0;
  await Promise.all((subs ?? []).map(async (s) => {
    try {
      await webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        JSON.stringify(msg),
        { TTL: 60 * 60 * 6, urgency: "high" },
      );
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) await db.from("push_subscriptions").delete().eq("id", s.id); // phone unsubscribed
      else console.error("push failed", code, (e as Error).message);
    }
  }));
  return sent;
}

Deno.serve(async (req) => {
  if (req.headers.get("x-notify-secret") !== Deno.env.get("NOTIFY_SECRET")) {
    return new Response("forbidden", { status: 403 });
  }
  const ev = await req.json();
  const url = SITE + "#w-" + ev.walk_id;
  const tag = "walk-" + ev.walk_id;
  let sent = 0;

  if (ev.type === "message") {
    const { data: w } = await db.from("walks").select("author_id,place").eq("id", ev.walk_id).maybeSingle();
    if (!w) return new Response("no walk");
    const { data: parts } = await db.from("walk_participants").select("user_id").eq("walk_id", ev.walk_id);
    const members = [w.author_id, ...(parts ?? []).map((p) => p.user_id)].filter((id) => id !== ev.user_id);
    const who = await nameOf(ev.user_id);
    const text = (ev.body || "").trim() || (ev.has_photo ? "📷 Фото" : "");
    sent = await send(await withoutBlockers(members, ev.user_id), {
      title: who + " · " + (w.place || "прогулка"),
      body: ev.has_photo && ev.body ? "📷 " + text : text,
      url, tag,
    });
  }

  if (ev.type === "join") {
    const { data: w } = await db.from("walks").select("author_id,place,start_at").eq("id", ev.walk_id).maybeSingle();
    if (!w || w.author_id === ev.user_id) return new Response("skip");
    const who = await nameOf(ev.user_id);
    sent = await send(await withoutBlockers([w.author_id], ev.user_id), {
      title: "🙋 " + who + " идёт с тобой гулять",
      body: (w.place || "Прогулка") + ", " + when(w.start_at),
      url, tag,
    });
  }

  if (ev.type === "cancel") {
    const who = await nameOf(ev.user_id);
    sent = await send(await withoutBlockers(ev.recipients ?? [], ev.user_id), {
      title: "Прогулка отменена",
      body: who + " отменил(а) прогулку: " + (ev.place || "") + ", " + when(ev.start_at),
      url: SITE, tag,
    });
  }

  return new Response(JSON.stringify({ sent }), { headers: { "Content-Type": "application/json" } });
});
