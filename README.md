# amplifi-contracts

Protocol contracts for Amplifi.

- `src/AmplifiLendingPool.sol`: the ERC-4626 lending pool leveraged positions borrow
  from. `borrow` is gated to one operator address; v2 repayments verify an atomic
  push from the recorded borrower wallet and retain unpaid debt. New deployments
  start with borrowing paused. Existing Polygon and Robinhood deployments retain
  their original behavior. The share token takes its name, symbol and
  decimals from the asset (`apUSD`, `aUSDG`), so one build serves any plain ERC-20
  that exposes a string `symbol()` and `decimals()`; one that does not reverts at
  deploy, and a rebasing or fee-on-transfer token does not fit the pool's
  balance-based accounting.
  Deposits are open to anyone until a depositor is whitelisted, either at deploy (the
  `DEPOSITORS` list, so the pool is never open in between) or later with
  `setDepositorWhitelisted`. From then on `deposit` and `mint` need both the caller and
  the share receiver on the list. Removing the last one opens deposits again, so add a
  replacement before removing the old address. Withdrawals are never restricted. Meant
  for the collateral-escrow margin pools, where the protocol is the only lender; the
  amplifi pools leave it empty.
- `src/RateAdminLendingPool.sol`: the pool with a delegated rate-admin role.
- `src/CollateralEscrow.sol`: remote-chain collateral with EIP-712 release attestations.

## Deploy

`script/Deploy.s.sol` defaults to Polygon and pUSD; every value can be overridden through
the environment, see `.env.example`, which also carries the Robinhood Chain values.

```
source .env
forge script script/Deploy.s.sol --rpc-url polygon   --private-key $PRIVATE_KEY --broadcast
forge script script/Deploy.s.sol --rpc-url robinhood --private-key $PRIVATE_KEY --broadcast
```

Set `OWNER_ADDRESS` to the final owner, distinct from the operational borrower key.
Both lending deploy scripts reject an identical owner/operator. Before funding or
unpausing, the owner must configure borrower admission, `setBorrowCaps`,
`setSettlementSigner`, and the agreed fee/rate policy, then verify those settings
and deployed bytecode. A later ownership change requires both `transferOwnership`
and `acceptOwnership` (Ownable2Step). Verify source on the chain's explorer.
On Robinhood Chain that is the Blockscout at
https://robinhoodchain.blockscout.com (the chain's explorer.mainnet host redirects
there; robinscan.io is a separate front end with no verify API):
`forge verify-contract --chain 4663 --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api --constructor-args $(cast abi-encode "constructor(address,address,address,uint256,uint256,uint256,uint256,address[])" <asset> <owner> <operator> <base> <kinkUtil> <kinkRate> <max> "[<depositors>]") <address> src/AmplifiLendingPool.sol:AmplifiLendingPool`,
with the constructor values the deploy printed (`"[]"` for an open pool).

## Repayment version 2

`repaymentVersion()` returns `2`. Callers must detect the version per pool; existing
loans retain their original pool address and repayment ABI until fully settled.

The borrower's wallet executes `beginRepay(loanId)`, token `transfer(pool, amount)`,
and `repay(loanId, amount)` in one atomic transaction. The first call accrues
interest before cash arrives and stores a transaction-local balance checkpoint.
The last call requires the exact observed transfer. Standard non-rebasing,
non-fee-on-transfer tokens only. The checkpoint uses EIP-1153 and requires a
Cancun-compatible chain and a relayer that accepts the entire three-call batch.

An EOA borrower such as Juiced's treasury cannot issue this batch by sending three
separate transactions. It instead approves a bounded token allowance and calls
`repayWithAllowance(loanId, amount)`, or `settleLossWithAllowance` with the same
loss-permit arguments below. These methods accrue before pulling funds and credit
only the measured transfer from the recorded borrower. Other callers cannot spend
that allowance. The Polygon deposit-wallet integration continues to use push
repayment because its relayer does not permit arbitrary spender approvals.
Juiced must explicitly integrate and stage-test the EOA path before its v2 rollout;
the Polygon backend changes do not establish Juiced readiness.

Repayment pays accrued interest before principal. A partial payment leaves the
loan open; it is not a loss. `RepaymentApplied` reports the actual net amount paid,
principal and interest allocation, and remaining principal/debt. The emitted
`received` equals `principalPaid + interestPaid`; excess and unrepresentable
repayment dust are returned to the same borrower and reported by
`RepaymentRefunded`. A partial amount too small to burn one normalized debt share
reverts. Use receipt amounts rather than the submitted amount for wallet budgets.

For a full close, the final batch call is `repayFull(loanId, amount)`. Submit a
bounded interest allowance within the loan's own recoverable funds; unused funds
are refunded. If mining is delayed beyond that allowance, `InsufficientRepayment`
reverts the entire atomic batch instead of silently converting the close to a
partial repayment. Reconcile and obtain a fresh quote before retrying. Ordinary
`repay` remains the deliberate partial-payment entrypoint.

Debt uses a cumulative interest index; another loan's payment cannot reduce a
borrower's principal or change its debt. Per-loan and aggregate values round up
independently. `DebtRoundingAdjustment` records the resulting pool asset gain: at
most one underlying base unit on repayment/write-off, and less than one normalized
debt share's value when issuing a loan. The index resets when no
debt shares remain. Quotes and accrual use the same index calculation.

`settleLoss(loanId, amount, maxWriteOff, nonce, deadline, signature)` verifies the
same atomic push, then closes the residual debt only with the configured settlement
signer's approval. The signer must differ from the borrower. The EIP-712 domain is
`AmplifiLendingPool`, version `2`, target chain ID and pool address. The signed type is:

```text
LossSettlement(uint256 loanId,address wallet,uint256 amount,uint256 maxWriteOff,uint256 nonce,uint256 deadline)
```

Nonces are single-use per pool (`usedSettlementNonces`). Loan IDs are never reused.
Use a short deadline and a bounded loss allowance; a stale or insufficient allowance
reverts and requires reconciliation before retrying. Never infer a loss from an
empty wallet or a failed RPC call. Zero recovery is supported by an authorized loss
settlement, not ordinary `repay(0)`.

`RepaymentApplied` describes the payment before any loss; `LoanWrittenOff` then
reports principal/interest written off and zero remaining debt. Fees accrue only
on interest actually paid. A settlement with a real residual loss does not charge a
fee on that payment; earlier partial-payment fees remain. A fully funded repayment
still charges its fee even if submitted through `settleLoss`.

The owner-only `writeOff(loanId, maxWriteOff)` is an exceptional path for inaccessible
borrower wallets. It recognizes loss without pretending funds were recovered. It
requires independent operational evidence and human approval. Later recovery is a
separate transfer to the original pool without minting lender shares; it does not
erase the lifetime bad-debt counter.

## Coordinated rollout

1. Review the contract and backend changes together. Validate target-chain EIP-1153
   support and the real deposit-wallet relayer batch before approving deployment.
2. Deploy replacements with the final owner and borrowing paused. Configure and
   verify token, borrower admission, caps, settlement signer, fee recipient and
   rates before funding. Record exact addresses and versions in the release manifest.
3. Deploy the backend that can read and settle both legacy and v2 loans. Exercise
   full/partial repayment, zero/partial loss, crash recovery and duplicate receipts
   on staging. Receipts are authoritative; partial payments must not mark loans repaid.
4. Reconcile old pool assets, loan outcomes and LP share holders. Agree treatment of
   unresolved losses before any holder redeems, so early redemptions do not shift
   losses to remaining holders. Each holder signs their own approved redemption;
   no private-key sharing or automatic custody consolidation is required.
5. Move only approved redeemable liquidity and route new loans to the verified v2
   pools. Keep old clients, borrowers and receipt processing available for old loans.
   Old pools may be put into irreversible `WindingDown`; repayments and redemptions
   remain available. Do not overwrite any existing loan's pool address.
6. Unpause new borrowing only after configuration and a supervised small canary
   pass. Monitor receipt allocations, residual debt, bad debt, pool cash, rounding
   adjustments and fees. Pausing v2 borrowing is reversible; old winding-down status
   is not. Rollback must continue servicing loans already issued by either version.

Escrow migration is separate from LP-share redemption. The backend currently has
global escrow configuration, so fully drain and reconcile old deposits, reservations,
claims and pending signatures before changing that configuration. Old signatures
remain bound to the old deployment. Do not seize customer collateral as a migration
shortcut. Overlapping escrow deployments require a separately reviewed backend
change with per-attestation deployment routing. Enabling a future seizure path
requires its own reviewed contract/backend deployment and explicit approval.

## Test

```
forge test
POLYGON_RPC_URL=https://... forge test --match-contract AmplifiLendingPoolForkTest -vv
```
