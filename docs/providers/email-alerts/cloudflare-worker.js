// Cloudflare Email Worker that relays bank alert emails to Sure.
//
// Route the inbound address (Email Routing -> Routing rules -> "Send to a
// Worker") to this worker, and set two variables on it:
//   SURE_WEBHOOK_URL  the inbound URL shown in Sure's Email alerts settings
//                     (secret; add it with `wrangler secret put` or as an
//                     encrypted variable in the dashboard)
//   FORWARD_TO        optional: a verified Email Routing destination that
//                     receives anything Sure does not take, such as Gmail's
//                     forwarding confirmation email
//
// The raw message is posted unmodified: Sure checks the bank's DKIM signature,
// which only verifies against the original bytes.

const MAX_BYTES = 2 * 1024 * 1024;

export default {
  async email(message, env) {
    if (message.rawSize > MAX_BYTES) {
      await passThrough(message, env, "too large");
      return;
    }

    const raw = await new Response(message.raw).arrayBuffer();
    let response;
    try {
      response = await fetch(env.SURE_WEBHOOK_URL, {
        method: "POST",
        headers: { "Content-Type": "message/rfc822" },
        body: raw,
      });
    } catch (error) {
      console.error("Sure unreachable", error);
      await passThrough(message, env, "sure unreachable");
      return;
    }

    if (response.status === 202) return;

    // 200 means Sure looked at the message and it is not a bank alert.
    await passThrough(message, env, `sure responded ${response.status}`);
  },
};

async function passThrough(message, env, reason) {
  console.log(`Not taken by Sure (${reason}): ${message.headers.get("subject")}`);
  if (env.FORWARD_TO) await message.forward(env.FORWARD_TO);
}
