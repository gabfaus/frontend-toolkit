# 21st cost and effect policy

## Default allowlist

Automatically call only an operation whose current metadata confirms all of the following:

- free;
- read-only;
- no AI credits;
- no copy/install quota;
- no mutation.

In the validated baseline, the default allowlist contains only `search`. The remote inventory is mutable: do not assume there will always be 35 tools or that names and classifications remain unchanged.

## Explicit authorization required

Ask immediately before executing any 21st operation that is:

- metered, generative, or consumes AI credits;
- subject to copy/install or retrieval quota;
- mutating, publishing, editing, deleting, bookmarking, or list-creating;
- account/profile changing;
- new, unclassified, or uncertain in cost or effect.

The current baseline includes `generate` and `iterate_generation` as metered generation. Installation/copy, publication, edit, delete, bookmark, list, and account/profile mutations also require authorization. A user's request to use “21st AI” identifies intent but does not waive a cost gate unless authorization to incur that cost is already clear and current.

Never infer safety only from a tool name. Compare the Toolkit lock/documentation baseline with current server metadata. If they disagree or metadata is insufficient, do not execute and ask the user.

Do not call account/usage tools merely to prove that a paid call did not happen when doing so is unnecessary or would expose account information.
