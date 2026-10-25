# Repayment verification

Run the multi-block scenario with its step-by-step repayment log:

```sh
forge test --match-contract RepaymentSequenceTest -vv
```

It uses two depositors and three loans opened at different times, advances both
block number and timestamp four times, and exercises interest-only, partial and
full payments, refunds, fee collection and lender exits. A separate dollar-based
10% annual-rate model checks each loan's debt/principal and aggregate accounting
after operations. It does not use the pool's index/share conversion helpers.
Final token conservation is exact; intermediate comparisons allow micro-unit
rounding differences. This deterministic scenario is not a stateful invariant
fuzzer or a test of different utilization-dependent rates.

## Stateful accounting campaign

```sh
forge test --match-contract RepaymentInvariantTest -vv
# Larger campaign:
FOUNDRY_INVARIANT_RUNS=2048 forge test --match-contract RepaymentInvariantTest -vv
```

The default is 512 sequences of 128 calls with unexpected reverts treated as
failures. Nine actions vary deposits, borrowing, time/block progression, partial
and full repayment, signed losses, withdrawals, donations, fee collection and
same-block deposit/withdraw round trips. Three initial loans start above the
utilization kink. The model covers four borrower wallets and three depositors,
with twelve reusable live-loan slots and a one-year time horizon.

An independent dollar model bounds interest and principal using elapsed time and
the rate curve, without reading the pool's index or conversion helpers. Small
integer intervals account for share/aggregate rounding; a width assertion keeps
them from becoming vacuous. Every step checks exact pool cash, total debt shares,
principal, fee/loss bounds and depositor share supply. Each sequence also closes
all surviving loans and checks that no debt shares remain. Same-block round trips
must not return more tokens than deposited. These are bounded tests, not a proof
for all durations, tokens or adversarial callbacks.

### Known loss/redemption edge case

`test_knownFullRedemptionAfterLossRevertsButCashCanBeWithdrawnByAssets` records a
remaining withdrawal issue. After a loss and repayment of surviving loans, the
last depositor's full-share quote can exceed actual cash because of virtual
assets/shares. The deterministic regression is short by 333 microdollars
($0.000333): full-share withdrawal reverts, while withdrawing the available asset
amount succeeds and leaves virtual-offset dust shares. The test expects the
current revert; passing it does not mean the defect is fixed. The same 333-unit
shortfall and revert reproduce against unchanged `develop`, so this predates the
repayment redesign. A correction to
withdrawal/conversion semantics requires separate specific human approval.

Run the execution forks:

```sh
POLYGON_RPC_URL=https://polygon-bor-rpc.publicnode.com \
ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
forge test --match-path test/RepaymentExecutionFork.t.sol -vv
```

Defaults are pinned to Polygon block 96,163,226 and Robinhood block 97,951,750.
Override with `POLYGON_FORK_BLOCK` and `ROBINHOOD_FORK_BLOCK`. Missing RPC variables
produce explicit skips; configured RPC failures fail the tests. Use an archive
RPC or an explicit newer block override if a public endpoint prunes the pinned state.

## EIP-7702 delegation without an RPC

```sh
forge test --match-contract Repayment7702Test -vv
```

These tests use `vm.signAndAttachDelegation` with a dummy EOA key and a self-call
batch executor. They assert the EOA's delegation marker and recorded borrower
identity, then check partial/full payments, refunds, signed loss, failed-batch
rollback, unauthorized callers and two loan repayments in one batch. No repayment
token approval is used. The test selects Prague execution rules with
`vm.setEvmVersion`; production bytecode remains compiled for Cancun. The local
executor is a test fixture, not the JuicedAccount implementation.

## Polygon deposit wallet

The tests deploy a wallet through the real factory at
`0x00000000000Fb5C9ADea0298D729A0CB3823Cc07`, using its deployed beacon implementation,
and deploy the proposed pool only on the fork. They sign the SDK-compatible
EIP-712 Batch/Call payload using a dummy test owner key and submit through the
factory's `proxy` entrypoint. The real pUSD contract moves the funds.

Only the fork's test relayer receives a factory operator role, granted by
impersonating the factory owner locally. Wallet signatures, nonce checks and
call execution are not mocked or bypassed. Tests cover partial/full repayment
across blocks, excess refunds, missing checkpoints, incorrect amounts, wrong
signatures, replay protection and atomic rollback of transfers and wallet nonces.

These tests do not contact the relayer HTTP service. They cannot establish its
target/call admission policy, queue behavior or submission/retry handling. A real
three-call relayer staging submission remains required.

Factory and wallet interfaces were checked against their verified Polygon code:

- [Factory](https://polygonscan.com/address/0x00000000000Fb5C9ADea0298D729A0CB3823Cc07#code)
- [Beacon implementation at the pinned block](https://polygonscan.com/address/0xf7f27C29e60fe6325beF8dA7F93250353d2e3294#code)

## Robinhood delegated treasury

Fixtures check the existing pool's asset and operator against the real USDG
token and treasury. The treasury's live EIP-7702 Simple7702Account delegation is
preserved. Tests exercise its actual delegated `executeBatch` with the atomic
`beginRepay -> transfer -> repay/repayFull/settleLoss` sequence, including
partial/full payment, accrued interest, refunds, unauthorized callers, failed-batch
rollback and signed loss settlement. Another test uses `vm.signAndAttachDelegation`
to delegate a fresh test EOA to the real deployed Simple7702Account implementation
and repay a loan recorded against that EOA. No repayment token approval is used.
Token balances are seeded with Foundry `deal`; no real funds or keys are used.

Passing these tests establishes that the push API works with that token
and treasury execution code. It does not establish Juiced application integration.
The Juiced source's `contracts/src/JuicedAccount.sol::_repayPool` currently pushes
tokens and calls the old `repay` without `beginRepay`; that path requires explicit
v2 adaptation and end-to-end coverage before migration. Testing the treasury's
executor alone does not make those user-account contracts compatible.

Neither fork sends transactions to a live network. They test new pool deployments,
not upgrades to existing deployed pools.
