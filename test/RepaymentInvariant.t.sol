// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AmplifiLendingPool} from "../src/AmplifiLendingPool.sol";
import {MockUSDC} from "./AmplifiLendingPool.t.sol";

contract InvariantBorrower {
    function pay(AmplifiLendingPool pool, MockUSDC token, uint256 id, uint256 amount, bytes memory loss) external {
        pool.beginRepay(id);
        if (amount != 0) token.transfer(address(pool), amount);
        if (loss.length == 0) {
            pool.repay(id, amount);
        } else {
            (bool ok, bytes memory result) = address(pool).call(loss);
            if (!ok) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        }
    }
}

contract RepaymentInvariantHandler is Test {
    struct Bounds {
        uint256 low;
        uint256 high;
    }

    struct LoanModel {
        uint256 id;
        Bounds debt;
        Bounds principal;
    }
    uint256 constant SIGNER_KEY = 0x1A51;
    uint256 constant YEAR_BPS = 365 days * 10_000;
    AmplifiLendingPool public pool;
    MockUSDC public token;
    InvariantBorrower[4] public borrowers;
    address[3] public lenders;
    LoanModel[12] public loans;
    Bounds public modelFees;
    Bounds public modelLoss;
    uint256 public expectedCash;
    uint256 public nextId = 1;
    uint256 public start;
    uint256 public repayments;
    uint256 public losses;
    uint256 public advances;
    uint256 public roundTrips;

    constructor() {
        start = block.timestamp;
        token = new MockUSDC();
        pool = new AmplifiLendingPool(
            address(token), address(this), address(this), 200, 8500, 2000, 10000, new address[](0)
        );
        pool.setBorrowPaused(false);
        pool.setProtocolFee(1000);
        pool.setSettlementSigner(vm.addr(SIGNER_KEY));
        for (uint256 i; i < 4; ++i) {
            borrowers[i] = new InvariantBorrower();
        }
        for (uint256 i; i < 3; ++i) {
            lenders[i] = address(uint160(0x10000 + i));
            _deposit(lenders[i], 100_000e6);
        }
        _borrow(0, 100_000e6);
        _borrow(1, 100_000e6);
        _borrow(2, 90_000e6);
    }

    function deposit(uint256 actor, uint256 raw) external {
        _deposit(lenders[actor % 3], bound(raw, 1e3, 50_000e6));
    }

    function _deposit(address lender, uint256 amount) internal {
        token.mint(lender, amount);
        vm.startPrank(lender);
        token.approve(address(pool), amount);
        pool.deposit(amount);
        vm.stopPrank();
        expectedCash += amount;
    }

    function borrow(uint256 slot, uint256 raw) external {
        _borrow(slot, raw);
    }

    function _borrow(uint256 slot, uint256 raw) internal {
        LoanModel storage loan = loans[slot % 12];
        if (loan.id != 0 || pool.availableLiquidity() < 100) return;
        uint256 max = pool.availableLiquidity();
        uint256 amount = bound(raw, 100, max < 100_000e6 ? max : 100_000e6);
        loan.id = nextId++;
        pool.borrow(loan.id, amount, address(borrowers[slot % 4]));
        // Over the bounded one-year horizon, one whole debt-share unit is worth less than 16 microdollars.
        loan.debt = Bounds(amount, amount + 16);
        loan.principal = Bounds(amount, amount);
        expectedCash -= amount;
    }

    function advance(uint256 raw) external {
        uint256 elapsed = bound(raw, 1, 2 days);
        if (block.timestamp + elapsed > start + 365 days) return;
        (uint256 low, uint256 high, uint256 count) = _totals();
        uint256 lowRate = _rate(low > count ? low - count : 0);
        uint256 highRate = _rate(high);
        for (uint256 i; i < 12; ++i) {
            LoanModel storage loan = loans[i];
            if (loan.id == 0) continue;
            uint256 lowGrowth = loan.debt.low * lowRate * elapsed / YEAR_BPS;
            uint256 highNumerator = loan.debt.high * highRate * elapsed;
            loan.debt.low += lowGrowth;
            if (loan.debt.low != 0) --loan.debt.low;
            loan.debt.high += (highNumerator + YEAR_BPS - 1) / YEAR_BPS + 1;
        }
        vm.roll(block.number + elapsed / 2 + 1);
        vm.warp(block.timestamp + elapsed);
        pool.accrueInterest();
        ++advances;
    }

    function repay(uint256 slot, uint256 raw, bool full) external {
        LoanModel storage loan = loans[slot % 12];
        if (loan.id == 0) return;
        uint256 debt = pool.loanDebt(loan.id);
        Bounds memory debtBefore = loan.debt;
        uint256 amount = full ? debt + raw % 1e6 : bound(raw, 1, debt);
        InvariantBorrower wallet = InvariantBorrower(pool.loanWallet(loan.id));
        token.mint(address(wallet), amount);
        uint256 before = token.balanceOf(address(wallet));
        try wallet.pay(pool, token, loan.id, amount, "") {}
        catch (bytes memory reason) {
            assertEq(bytes4(reason), AmplifiLendingPool.RepaymentTooSmall.selector);
            assertEq(token.balanceOf(address(wallet)), before);
            return;
        }
        uint256 paid = before - token.balanceOf(address(wallet));
        expectedCash += paid;
        Bounds memory interest = _interest(loan);
        modelFees.low += _min(paid, interest.low) / 10;
        modelFees.high += _min(paid, interest.high) / 10;
        if (full) {
            _within(paid, loan.debt);
            delete loans[slot % 12];
        } else {
            loan.principal.low = _sub(loan.principal.low, _sub(paid, interest.low));
            loan.principal.high = _sub(loan.principal.high, _sub(paid, interest.high));
            loan.debt.low = _sub(loan.debt.low, paid + 1);
            loan.debt.high = _sub(loan.debt.high, paid) + 1;
            if (pool.loanShares(loan.id) == 0) {
                _within(paid, debtBefore);
                delete loans[slot % 12];
            }
        }
        ++repayments;
    }

    function settleLoss(uint256 slot, uint256 raw) external {
        LoanModel storage loan = loans[slot % 12];
        if (loan.id == 0) return;
        uint256 debt = pool.loanDebt(loan.id);
        uint256 amount = raw % (debt / 2 + 1);
        address wallet = pool.loanWallet(loan.id);
        bytes memory loss = _lossCall(loan.id, wallet, amount, debt);
        token.mint(wallet, amount);
        InvariantBorrower(wallet).pay(pool, token, loan.id, amount, loss);
        expectedCash += amount;
        modelLoss.low += _sub(loan.debt.low, amount);
        modelLoss.high += _sub(loan.debt.high, amount);
        delete loans[slot % 12];
        ++losses;
    }

    function _lossCall(uint256 id, address wallet, uint256 amount, uint256 debt) internal view returns (bytes memory) {
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
            keccak256(abi.encode(pool.LOSS_SETTLEMENT_TYPEHASH(), id, wallet, amount, debt, id, deadline));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, keccak256(abi.encodePacked("\x19\x01", domain, contents)));
        return abi.encodeCall(pool.settleLoss, (id, amount, debt, id, deadline, abi.encodePacked(r, s, v)));
    }

    function withdraw(uint256 actor, uint256 raw) external {
        address lender = lenders[actor % 3];
        uint256 balance = pool.balanceOf(lender);
        if (balance == 0) return;
        uint256 shares = bound(raw, 1, balance);
        uint256 assets = pool.sharesToAssets(shares);
        if (assets == 0 || assets > pool.availableLiquidity()) return;
        uint256 before = token.balanceOf(lender);
        vm.prank(lender);
        uint256 withdrawn = pool.withdraw(shares);
        assertEq(token.balanceOf(lender) - before, withdrawn);
        expectedCash -= withdrawn;
    }

    function donate(uint256 raw) external {
        uint256 amount = bound(raw, 1, 100e6);
        token.mint(address(this), amount);
        token.transfer(address(pool), amount);
        expectedCash += amount;
    }

    function collectFees(uint256 raw) external {
        uint256 accrued = pool.protocolFeesAccrued();
        if (accrued == 0) return;
        uint256 amount = bound(raw, 1, accrued);
        pool.collectProtocolFees(address(this), amount);
        expectedCash -= amount;
        modelFees.low = _sub(modelFees.low, amount);
        modelFees.high = _sub(modelFees.high, amount);
    }

    function roundTrip(uint256 raw) external {
        uint256 amount = bound(raw, 1e3, 1_000_000e6);
        token.mint(address(this), amount);
        token.approve(address(pool), amount);
        uint256 before = token.balanceOf(address(this));
        uint256 shares = pool.deposit(amount);
        uint256 returned = pool.withdraw(shares);
        assertLe(returned, amount, "same-block round trip cannot extract lender funds");
        assertEq(token.balanceOf(address(this)), before - amount + returned);
        expectedCash += amount - returned;
        ++roundTrips;
    }

    function assertAccounting() external view {
        uint256 sumShares;
        for (uint256 i; i < 12; ++i) {
            LoanModel memory loan = loans[i];
            if (loan.id == 0) continue;
            _within(pool.loanDebt(loan.id), loan.debt);
            _within(pool.loanPrincipal(loan.id), loan.principal);
            assertGe(pool.loanDebt(loan.id), pool.loanPrincipal(loan.id));
            sumShares += pool.loanShares(loan.id);
            assertLe(loan.debt.high - loan.debt.low, 1000 + loan.debt.high / 1000, "reference interval too wide");
        }
        (uint256 low, uint256 high, uint256 count) = _totals();
        assertEq(pool.totalBorrowShares(), sumShares);
        _within(pool.totalBorrowAssets(), Bounds(_sub(low, count), high));
        assertEq(token.balanceOf(address(pool)), expectedCash, "exact token conservation");
        _within(pool.protocolFeesAccrued(), modelFees);
        _within(pool.totalBadDebtRealized(), modelLoss);
        _within(
            pool.totalAssets(),
            Bounds(_sub(expectedCash + _sub(low, count), modelFees.high), _sub(expectedCash + high, modelFees.low))
        );
        uint256 supply = pool.balanceOf(address(this));
        for (uint256 i; i < 3; ++i) {
            supply += pool.balanceOf(lenders[i]);
        }
        assertEq(pool.totalSupply(), supply);
    }

    function closeAllLoans() external {
        for (uint256 i; i < 12; ++i) {
            if (loans[i].id != 0) this.repay(i, 0, true);
        }
        this.collectFees(type(uint256).max);
        this.assertAccounting();
        assertEq(pool.totalBorrowAssets(), 0);
        assertEq(pool.totalBorrowShares(), 0);
    }

    function _totals() internal view returns (uint256 low, uint256 high, uint256 count) {
        for (uint256 i; i < 12; ++i) {
            if (loans[i].id != 0) {
                low += loans[i].debt.low;
                high += loans[i].debt.high;
                ++count;
            }
        }
    }

    function _rate(uint256 debt) internal view returns (uint256) {
        uint256 util = debt == 0 ? 0 : debt * 10_000 / (expectedCash + debt);
        return util <= 8500 ? 200 + 1800 * util / 8500 : 2000 + 8000 * (util - 8500) / 1500;
    }

    function _interest(LoanModel storage loan) internal view returns (Bounds memory) {
        return Bounds(_sub(loan.debt.low, loan.principal.high), _sub(loan.debt.high, loan.principal.low));
    }

    function _within(uint256 value, Bounds memory range) internal pure {
        assertGe(value, range.low);
        assertLe(value, range.high);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function _sub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }
}

contract RepaymentInvariantTest is StdInvariant, Test {
    RepaymentInvariantHandler handler;

    function setUp() public {
        handler = new RepaymentInvariantHandler();
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.borrow.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.repay.selector;
        selectors[4] = handler.settleLoss.selector;
        selectors[5] = handler.withdraw.selector;
        selectors[6] = handler.donate.selector;
        selectors[7] = handler.collectFees.selector;
        selectors[8] = handler.roundTrip.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_cashDebtPrincipalFeesAndLossAgreeWithModel() public view {
        handler.assertAccounting();
    }

    function afterInvariant() public {
        handler.closeAllLoans();
    }

    function test_knownFullRedemptionAfterLossRevertsButCashCanBeWithdrawnByAssets() public {
        handler.settleLoss(1, 15377);
        handler.closeAllLoans();
        AmplifiLendingPool pool = handler.pool();
        MockUSDC token = handler.token();
        for (uint256 i; i < 2; ++i) {
            address lender = handler.lenders(i);
            uint256 shares = pool.balanceOf(lender);
            vm.prank(lender);
            pool.withdraw(shares);
        }
        address last = handler.lenders(2);
        uint256 lastShares = pool.balanceOf(last);
        uint256 cash = token.balanceOf(address(pool));
        assertEq(pool.sharesToAssets(lastShares) - cash, 333);
        vm.prank(last);
        vm.expectRevert(AmplifiLendingPool.InsufficientLiquidity.selector);
        pool.withdraw(lastShares);
        assertEq(pool.balanceOf(last), lastShares);
        vm.prank(last);
        pool.withdrawAssets(cash);
        assertEq(token.balanceOf(address(pool)), 0);
        assertGt(pool.balanceOf(last), 0, "unfunded virtual-offset dust shares remain");
    }
}
