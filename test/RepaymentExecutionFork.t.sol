// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {AmplifiLendingPool} from "../src/AmplifiLendingPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

struct WalletCall {
    address target;
    uint256 value;
    bytes data;
}

struct WalletBatch {
    address wallet;
    uint256 nonce;
    uint256 deadline;
    WalletCall[] calls;
}

// ABI from the verified Polygon factory, matching the backend SDK's Batch/Call types.
interface IDepositFactoryFork {
    function owner() external view returns (address);
    function grantRoles(address user, uint256 roles) external;
    function deploy(address[] calldata owners, bytes32[] calldata ids) external;
    function predictWalletAddress(bytes32 id) external view returns (address);
    function proxy(WalletBatch[] calldata batches, bytes[] calldata signatures) external;
}

interface IDepositWalletFork {
    function nonce() external view returns (uint256);
    function owner() external view returns (address);
}

interface ISimple7702Fork {
    function executeBatch(WalletCall[] calldata calls) external;
}

abstract contract RepaymentForkBase is Test {
    bool forkActive;

    function _fork(string memory rpcEnv, string memory blockEnv, uint256 defaultBlock, uint256 chainId) internal {
        string memory rpc = vm.envOr(rpcEnv, string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc, vm.envOr(blockEnv, defaultBlock));
        assertEq(block.chainid, chainId, "wrong fork network");
        forkActive = true;
    }

    modifier onlyFork() {
        vm.skip(!forkActive);
        _;
    }
}

contract DepositWalletRepaymentForkTest is RepaymentForkBase {
    address constant PUSD = 0xC011a7E12a19f7B1f670d46F03B03f3342E82DFB;
    IDepositFactoryFork constant FACTORY = IDepositFactoryFork(0x00000000000Fb5C9ADea0298D729A0CB3823Cc07);
    uint256 constant TEST_OWNER_KEY = 0xA11CE;
    AmplifiLendingPool pool;
    IERC20 token;
    address wallet;

    function setUp() public {
        _fork("POLYGON_RPC_URL", "POLYGON_FORK_BLOCK", 96_163_226, 137);
        if (!forkActive) return;
        vm.txGasPrice(1 gwei);
        token = IERC20(PUSD);
        assertGt(address(FACTORY).code.length, 0);
        // Grant only the test relayer role on the fork; wallet ownership/signatures remain real checks.
        address factoryOwner = FACTORY.owner();
        vm.prank(factoryOwner);
        FACTORY.grantRoles(address(this), 2);
        address[] memory owners = new address[](1);
        bytes32[] memory ids = new bytes32[](1);
        owners[0] = vm.addr(TEST_OWNER_KEY);
        ids[0] = keccak256("repayment fork fixture");
        wallet = FACTORY.predictWalletAddress(ids[0]);
        FACTORY.deploy(owners, ids);
        assertGt(wallet.code.length, 0);
        assertEq(IDepositWalletFork(wallet).owner(), owners[0]);
        pool = new AmplifiLendingPool(PUSD, address(this), address(this), 1000, 8500, 1000, 1000, new address[](0));
        pool.setBorrowPaused(false);
        deal(PUSD, address(this), 10_000e6);
        token.approve(address(pool), 10_000e6);
        pool.deposit(10_000e6);
        pool.borrow(1, 1_000e6, wallet);
    }

    function test_fork_signedThreeCallBatchPartialThenFullAcrossBlocks() public onlyFork {
        vm.roll(block.number + 100);
        vm.warp(block.timestamp + 1 days);
        uint256 debtBefore = pool.loanDebt(1);
        _submit(_calls(200e6, 200e6, false), TEST_OWNER_KEY);
        assertApproxEqAbs(pool.loanDebt(1), debtBefore - 200e6, 1);
        assertGt(pool.loanPrincipal(1), 800e6, "payment pays interest first");
        assertEq(token.balanceOf(wallet), 800e6);
        assertEq(IDepositWalletFork(wallet).nonce(), 1);

        vm.roll(block.number + 200);
        vm.warp(block.timestamp + 2 days);
        uint256 debt = pool.loanDebt(1);
        deal(PUSD, wallet, debt + 10e6);
        uint256 cash = token.balanceOf(address(pool));
        _submit(_calls(debt + 10e6, debt + 10e6, true), TEST_OWNER_KEY);
        assertEq(pool.loanDebt(1), 0);
        assertEq(pool.totalBorrowShares(), 0);
        assertEq(pool.totalBadDebtRealized(), 0);
        assertEq(token.balanceOf(wallet), 10e6, "excess refunded to actual wallet");
        assertEq(token.balanceOf(address(pool)), cash + debt);
        assertEq(IDepositWalletFork(wallet).nonce(), 2);
    }

    function test_fork_failedFinalCallRollsBackTokenTransferAndWalletNonce() public onlyFork {
        WalletCall[] memory calls = _calls(200e6, 201e6, false);
        (WalletBatch[] memory batches, bytes[] memory signatures) = _signed(calls, TEST_OWNER_KEY);
        uint256 cash = token.balanceOf(address(pool));
        vm.expectRevert(
            abi.encodeWithSignature(
                "BatchCallFailed(uint256,address,bytes)",
                2,
                address(pool),
                abi.encodeWithSelector(AmplifiLendingPool.RepaymentAmountMismatch.selector)
            )
        );
        FACTORY.proxy(batches, signatures);
        assertEq(token.balanceOf(wallet), 1_000e6);
        assertEq(token.balanceOf(address(pool)), cash);
        assertEq(pool.loanDebt(1), 1_000e6);
        assertEq(IDepositWalletFork(wallet).nonce(), 0);
        _submit(_calls(200e6, 200e6, false), TEST_OWNER_KEY);
        assertEq(pool.loanDebt(1), 800e6, "reverted checkpoint does not block retry");
    }

    function test_fork_wrongOwnerSignatureCannotMoveFunds() public onlyFork {
        (WalletBatch[] memory batches, bytes[] memory signatures) = _signed(_calls(200e6, 200e6, false), 0xBAD);
        vm.expectRevert(bytes4(keccak256("InvalidSignature()")));
        FACTORY.proxy(batches, signatures);
        assertEq(token.balanceOf(wallet), 1_000e6);
        assertEq(pool.loanDebt(1), 1_000e6);
        assertEq(IDepositWalletFork(wallet).nonce(), 0);
    }

    function test_fork_missingCheckpointRevertsTransfer() public onlyFork {
        WalletCall[] memory original = _calls(200e6, 200e6, false);
        WalletCall[] memory calls = new WalletCall[](2);
        calls[0] = original[1];
        calls[1] = original[2];
        (WalletBatch[] memory batches, bytes[] memory signatures) = _signed(calls, TEST_OWNER_KEY);
        vm.expectRevert(
            abi.encodeWithSignature(
                "BatchCallFailed(uint256,address,bytes)",
                1,
                address(pool),
                abi.encodeWithSelector(AmplifiLendingPool.RepaymentNotStarted.selector)
            )
        );
        FACTORY.proxy(batches, signatures);
        assertEq(token.balanceOf(wallet), 1_000e6);
        assertEq(pool.loanDebt(1), 1_000e6);
        assertEq(IDepositWalletFork(wallet).nonce(), 0);
    }

    function test_fork_signedBatchCannotBeReplayed() public onlyFork {
        (WalletBatch[] memory batches, bytes[] memory signatures) = _signed(_calls(200e6, 200e6, false), TEST_OWNER_KEY);
        FACTORY.proxy(batches, signatures);
        vm.expectRevert(bytes4(keccak256("InvalidNonce()")));
        FACTORY.proxy(batches, signatures);
        assertEq(pool.loanDebt(1), 800e6);
        assertEq(token.balanceOf(wallet), 800e6);
    }

    function _calls(uint256 transferred, uint256 claimed, bool full) internal view returns (WalletCall[] memory calls) {
        calls = new WalletCall[](3);
        calls[0] = WalletCall(address(pool), 0, abi.encodeCall(pool.beginRepay, (1)));
        calls[1] = WalletCall(PUSD, 0, abi.encodeCall(token.transfer, (address(pool), transferred)));
        calls[2] = WalletCall(
            address(pool),
            0,
            full ? abi.encodeCall(pool.repayFull, (1, claimed)) : abi.encodeCall(pool.repay, (1, claimed))
        );
    }

    function _submit(WalletCall[] memory calls, uint256 key) internal {
        (WalletBatch[] memory batches, bytes[] memory signatures) = _signed(calls, key);
        FACTORY.proxy(batches, signatures);
    }

    function _signed(WalletCall[] memory calls, uint256 key)
        internal
        view
        returns (WalletBatch[] memory batches, bytes[] memory signatures)
    {
        batches = new WalletBatch[](1);
        batches[0] = WalletBatch(wallet, IDepositWalletFork(wallet).nonce(), block.timestamp + 1200, calls);
        bytes32 callType = keccak256("Call(address target,uint256 value,bytes data)");
        bytes32[] memory hashes = new bytes32[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            hashes[i] = keccak256(abi.encode(callType, calls[i].target, calls[i].value, keccak256(calls[i].data)));
        }
        bytes32 batchHash = keccak256(
            abi.encode(
                keccak256(
                    "Batch(address wallet,uint256 nonce,uint256 deadline,Call[] calls)Call(address target,uint256 value,bytes data)"
                ),
                wallet,
                batches[0].nonce,
                batches[0].deadline,
                keccak256(abi.encodePacked(hashes))
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("DepositWallet"),
                keccak256("1"),
                block.chainid,
                wallet
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, batchHash)));
        signatures = new bytes[](1);
        signatures[0] = abi.encodePacked(r, s, v);
    }
}

contract JuicedAllowanceRepaymentForkTest is RepaymentForkBase {
    address constant LIVE_POOL = 0x98Cd06BFff15eC71be707Ae7214297f65DfFf5aC;
    address constant TREASURY = 0xe48ED751565F1CA658cac5E2bb226Ca2D73196d8;
    address constant TOKEN = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint256 constant SETTLEMENT_KEY = 0x51A;
    AmplifiLendingPool pool;
    IERC20 token;

    function setUp() public {
        _fork("ROBINHOOD_RPC_URL", "ROBINHOOD_FORK_BLOCK", 97_767_524, 4663);
        if (!forkActive) return;
        assertEq(AmplifiLendingPool(LIVE_POOL).asset(), TOKEN);
        assertEq(AmplifiLendingPool(LIVE_POOL).teeOperator(), TREASURY);
        assertEq(
            TREASURY.code,
            hex"ef0100e6cae83bde06e4c305530e199d7217f42808555b",
            "preserve the live treasury's Simple7702Account delegation"
        );
        token = IERC20(TOKEN);
        pool = new AmplifiLendingPool(TOKEN, address(this), TREASURY, 1000, 8500, 1000, 1000, new address[](0));
        pool.setBorrowPaused(false);
        pool.setSettlementSigner(vm.addr(SETTLEMENT_KEY));
        deal(TOKEN, address(this), 10_000e6);
        token.approve(address(pool), 10_000e6);
        pool.deposit(10_000e6);
        deal(TOKEN, TREASURY, 0);
        vm.prank(TREASURY);
        pool.borrow(1, 1_000e6, TREASURY);
    }

    function test_fork_treasuryApprovePartialThenFullWithInterestAndRefund() public onlyFork {
        vm.prank(TREASURY);
        token.approve(address(pool), type(uint256).max);
        vm.roll(block.number + 100);
        vm.warp(block.timestamp + 1 days);
        uint256 debt = pool.loanDebt(1);
        uint256 cash = token.balanceOf(address(pool));
        vm.prank(TREASURY);
        pool.repayWithAllowance(1, 200e6);
        assertApproxEqAbs(pool.loanDebt(1), debt - 200e6, 1);
        assertGt(pool.loanPrincipal(1), 800e6);
        assertEq(token.balanceOf(address(pool)), cash + 200e6);

        vm.roll(block.number + 200);
        vm.warp(block.timestamp + 2 days);
        debt = pool.loanDebt(1);
        deal(TOKEN, TREASURY, debt + 10e6);
        cash = token.balanceOf(address(pool));
        vm.prank(TREASURY);
        pool.repayWithAllowance(1, debt + 10e6);
        assertEq(pool.loanDebt(1), 0);
        assertEq(pool.totalBorrowShares(), 0);
        assertEq(pool.totalBadDebtRealized(), 0);
        assertEq(token.balanceOf(TREASURY), 10e6);
        assertEq(token.balanceOf(address(pool)), cash + debt);
    }

    function test_fork_missingApprovalAndWrongCallerPreserveFundsAndDebt() public onlyFork {
        uint256 cash = token.balanceOf(address(pool));
        vm.prank(TREASURY);
        vm.expectRevert();
        pool.repayWithAllowance(1, 200e6);
        vm.prank(TREASURY);
        token.approve(address(pool), 200e6);
        vm.expectRevert(AmplifiLendingPool.OnlyBorrowerWallet.selector);
        pool.repayWithAllowance(1, 200e6);
        assertEq(token.balanceOf(TREASURY), 1_000e6);
        assertEq(token.balanceOf(address(pool)), cash);
        assertEq(pool.loanDebt(1), 1_000e6);
        assertEq(token.allowance(TREASURY, address(pool)), 200e6);
    }

    function test_fork_treasuryDelegatedBatchApprovesAndRepaysAtomically() public onlyFork {
        WalletCall[] memory calls = new WalletCall[](2);
        calls[0] = WalletCall(TOKEN, 0, abi.encodeCall(token.approve, (address(pool), 200e6)));
        calls[1] = WalletCall(address(pool), 0, abi.encodeCall(pool.repayWithAllowance, (1, 200e6)));
        vm.prank(TREASURY);
        ISimple7702Fork(TREASURY).executeBatch(calls);
        assertEq(token.balanceOf(TREASURY), 800e6);
        assertEq(pool.loanDebt(1), 800e6);
        assertEq(token.allowance(TREASURY, address(pool)), 0);
    }

    function test_fork_treasurySignedLossPullsOnlyAuthorizedAmount() public onlyFork {
        vm.roll(block.number + 100);
        vm.warp(block.timestamp + 1 days);
        uint256 debt = pool.loanDebt(1);
        uint256 deadline = block.timestamp + 300;
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("AmplifiLendingPool"),
                keccak256("2"),
                block.chainid,
                address(pool)
            )
        );
        bytes32 contents =
            keccak256(abi.encode(pool.LOSS_SETTLEMENT_TYPEHASH(), 1, TREASURY, 400e6, debt - 400e6, 1, deadline));
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(SETTLEMENT_KEY, keccak256(abi.encodePacked("\x19\x01", domain, contents)));
        vm.startPrank(TREASURY);
        token.approve(address(pool), 400e6);
        pool.settleLossWithAllowance(1, 400e6, debt - 400e6, 1, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();
        assertEq(token.balanceOf(TREASURY), 600e6);
        assertEq(pool.loanDebt(1), 0);
        assertEq(pool.totalBadDebtRealized(), debt - 400e6);
        assertEq(token.allowance(TREASURY, address(pool)), 0);
    }
}
