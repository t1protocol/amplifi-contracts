# Replacement escrow gate

Seizure is permanently removed: no seizer role or enable switch remains. Any future seizure feature needs a separately audited contract design. Releases retain the Amplifi / version 1 domain and existing tuple; old signatures remain bound to the old verifying contract.

Deploy with OWNER_ADDRESS (final cold owner), COLLATERAL_TOKEN_ADDRESS, ATTESTER_ADDRESS (different from owner), ESCROW_PER_ATTESTATION_CAP, ESCROW_DAILY_RELEASE_LIMIT, and ESCROW_MAX_ATTESTATION_TTL. Caps use token smallest units, must be positive, and daily must cover the per-release cap. Additional tokens need their own caps before enablement. The constructor installs authority and configuration atomically. Broadcast requires approved addresses/configuration and human supervision.

No dual active escrow route is introduced. Keep the old escrow configured until these gates pass:

1. Coordinate a maintenance window stopping new deposits, credit issuance, and new exposure, while keeping legitimate release processing available. Pausing the old escrow also pauses withdrawals.
2. Reconcile the watcher through a settled block and resolve claimed/uncredited deposits, RESERVED rolls, REPAID unsigned releases, and all pending transaction/relayer submissions. Unknown submissions block migration; do not retry or discard them.
3. Close exposure and settle all original/refill margin loans across current and legacy pools. Check outstanding principal and receipt-backed onchain debt settlement.
4. Reconcile every depositor/token and have each actual account owner claim old-domain releases. Expired unclaimed releases still owe money: reissue and claim against the old domain. Expiry alone does not discharge liabilities. Never VOID historical SIGNED rows for cleanup because that restores deducted entitlement.
5. Reconcile consumed events and confirm zero account balances, zero unclaimed liabilities, and no pending attestations. Explain residual ERC20 balance as cushion/donation. There is no admin sweep; residual funds block a literal full-fund drain until a separately approved disposition exists.
6. Apply backend migration265 before editing account/config addresses. It preserves attestation escrow address and chain from account records; missing mappings intentionally fail migration. Record a final settled snapshot and preserve historical records/cursors.
7. Only after the gates pass, switch service, watcher, account config, and client together. Historical payloads must use their own escrow address, never the replacement global address. Verify replacement bytecode/config, fund the approved cushion, and run one small deposit/borrow/full-repay/release before broad reopening.

Per-token caps include profit releases paid from the cushion. Cap changes preserve spending within the current day. Caps do not replace cold-owner/attester separation.
