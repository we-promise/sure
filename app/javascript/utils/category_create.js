// Creates a category through the categories JSON endpoint. Shared by the
// category pickers (DS::CategorySelect and the transaction list's quick
// picker) so both send the same request and read errors the same way.
//
// Resolves to { category } on success, or { error } on failure, where `error`
// is the server's message when it sent one (null means "use your default").
export async function createCategory({ url, name, color, parentId = null }) {
  try {
    const response = await fetch(url, {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken(),
      },
      body: JSON.stringify({
        category: {
          name,
          color,
          ...(parentId ? { parent_id: parentId } : {}),
        },
      }),
    });
    const body = await response.json().catch(() => ({}));

    if (!response.ok || !body.id) return { error: errorMessage(body) };

    return { category: body };
  } catch {
    return { error: null };
  }
}

function errorMessage(body) {
  return body.errors?.join(", ") || body.error || body.message || null;
}

function csrfToken() {
  return document.querySelector('meta[name="csrf-token"]')?.content;
}
