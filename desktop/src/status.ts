import { S } from "./strings";

// Shared mapping of a check_server / server-command failure to a user-facing
// status. check_server raises ServerError::InvalidUrl (Display "Invalid server
// URL: …") for malformed URLs; everything else is treated as unreachable.
export function serverErrorMessage(e: unknown): string {
  return String(e).includes("Invalid") ? S.invalidUrl : S.unreachable;
}
