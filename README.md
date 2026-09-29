# amplifi-contracts

Protocol contracts for Amplifi.

- `src/AmplifiLendingPool.sol`: the ERC-4626 lending pool leveraged positions borrow
  from. `borrow` is gated to one operator address; `repay` is push based and only the
  loan's borrower wallet may call it. Deployed on Polygon with pUSD; a USDG deploy on
  Robinhood Chain for Juiced is next. The share token takes its name, symbol and
  decimals from the asset (`apUSD`, `aUSDG`), so one build serves any plain ERC-20
  that exposes a string `symbol()` and `decimals()`; one that does not reverts at
  deploy, and a rebasing or fee-on-transfer token does not fit the pool's
  balance-based accounting.
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
chain's explorer. On Robinhood Chain that is the Blockscout at
https://robinhoodchain.blockscout.com (the chain's explorer.mainnet host redirects
there; robinscan.io is a separate front end with no verify API):
`forge verify-contract --chain 4663 --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api --constructor-args $(cast abi-encode "constructor(address,address,address,uint256,uint256,uint256,uint256)" <asset> <owner> <operator> <base> <kinkUtil> <kinkRate> <max>) <address> src/AmplifiLendingPool.sol:AmplifiLendingPool`,
with the seven constructor values the deploy printed.

## Test

```
forge test
POLYGON_RPC_URL=https://... forge test --match-contract AmplifiLendingPoolForkTest -vv
```
