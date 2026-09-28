# amplifi-contracts

Protocol contracts for Amplifi.

- `src/AmplifiLendingPool.sol`: the ERC-4626 lending pool leveraged positions borrow
  from. `borrow` is gated to one operator address; `repay` is push based and only the
  loan's borrower wallet may call it. Deployed on Polygon with pUSD, and on Robinhood
  Chain with USDG for Juiced. The share token takes its name, symbol and decimals from
  the asset (`apUSD`, `aUSDG`), so one build serves every asset.
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

After the deploy: `transferOwnership` to the final owner and have them `acceptOwnership`
(Ownable2Step), set the borrow caps with `setBorrowCaps`, and verify the source on the
chain's explorer (Polygonscan; Robinscan at https://robinscan.io, a Blockscout instance,
takes `forge verify-contract --verifier blockscout --verifier-url https://robinscan.io/api`).

## Test

```
forge test
POLYGON_RPC_URL=https://... forge test --match-contract AmplifiLendingPoolForkTest -vv
```
