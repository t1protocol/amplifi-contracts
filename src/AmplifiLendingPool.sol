// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

enum PoolStatus {
    Active,
    WindingDown,
    Closed
}

error ZeroAddress();

/// @dev The share token is named after the asset it holds, and carries the asset's
///      decimals (the ERC-4626 convention), so one build serves a pUSD pool on Polygon
///      ("apUSD", 6) and a USDG or WETH pool elsewhere ("aUSDG" 6, "aWETH" 18). The asset
///      must expose a string `symbol()` and `decimals()`; one that does not (a bytes32
///      symbol, say) reverts here, at deploy time. These run as base-constructor arguments,
///      before the constructor body, so the zero-asset check lives here too.
function shareName(address asset) view returns (string memory) {
    if (asset == address(0)) revert ZeroAddress();
    return string.concat("Amplifi ", IERC20Metadata(asset).symbol(), " Lending Share");
}

function shareSymbol(address asset) view returns (string memory) {
    return string.concat("a", IERC20Metadata(asset).symbol());
}

contract AmplifiLendingPool is ERC20, IERC4626, ReentrancyGuard, Ownable2Step, EIP712 {
    using SafeERC20 for IERC20;

    // ── Immutables ──────────────────────────────────────────────────────
    // The asset. Named for the first deploy and kept for the ABI; asset() is
    // the ERC-4626 name for the same address.
    IERC20 public immutable usdc;
    uint8 private immutable SHARE_DECIMALS;

    // ── State ───────────────────────────────────────────────────────────
    address public teeOperator;
    PoolStatus public status;
    uint256 public totalBorrowAssets;
    uint256 public totalBorrowShares;
    uint256 public borrowIndex = 1e27;
    uint256 public lastAccrualTimestamp;

    // ── Loan tracking ─────────────────────────────────────────────────
    mapping(uint256 loanId => uint256 shares) public loanShares;
    // Per-loan borrower wallet. borrow() disburses the principal here, and repay()
    // is called BY this wallet after it has pushed the repayment to the pool (see
    // repay()). Replaces the single global fundAccount so funds flow
    // pool<->deposit-wallet directly, no commingling, and each loan's borrower is
    // recorded on-chain and gates who may repay it.
    mapping(uint256 loanId => address wallet) public loanWallet;
    mapping(uint256 loanId => uint256 principal) public loanPrincipal;

    // ── Protocol fee ────────────────────────────────────────────────────
    uint256 public feeBps;
    address public feeRecipient;
    uint256 public protocolFeesAccrued;

    // ── Interest Rate Model ─────────────────────────────────────────────
    uint256 public baseRateBps;
    uint256 public kinkUtilizationBps;
    uint256 public kinkRateBps;
    uint256 public maxRateBps;

    // ── Risk controls (direct-routing operator blast-radius mitigation) ──
    // In the direct-routing model borrow() disburses to any `wallet` the teeOperator
    // names. A compromised operator hot key could otherwise route the pool's entire
    // available liquidity to an address it controls. These OWNER-gated controls bound
    // and constrain that: they change nothing until an owner sets them (all default to
    // 0 / false), so existing behaviour is preserved.

    // Optional borrower-wallet allowlist. When enabled, borrow() only disburses to
    // pre-approved wallets, fully restoring the "operator cannot divert funds to an
    // arbitrary address" invariant, PROVIDED the owner (who manages the list) is a
    // colder key than the hot teeOperator. Off by default (behaviour-neutral).
    bool public borrowAllowlistEnabled;
    mapping(address wallet => bool allowed) public allowedBorrowerWallet;

    // Optional depositor whitelist. While nobody is on it (count 0) anyone can deposit;
    // once an address is added, deposit and mint need both the caller and the share
    // receiver whitelisted. Withdrawals are never restricted. Seed it at deploy so the
    // pool is never open in between.
    mapping(address depositor => bool whitelisted) public isDepositorWhitelisted;
    uint256 public depositorWhitelistCount;

    // Borrow circuit breakers (0 = disabled). `maxBorrowPerLoan` caps a single borrow;
    // `maxBorrowPerWindow` caps cumulative borrows inside a rolling `borrowWindow`
    // (tumbling), bounding how much a compromised operator can drain in one burst before
    // monitoring/owner can react (Close the pool, rotate the operator).
    uint256 public maxBorrowPerLoan;
    uint256 public maxBorrowPerWindow;
    uint256 public borrowWindow;
    uint256 public windowStart;
    uint256 public windowBorrowed;

    // Cumulative bad debt realized across all loans, a cheap on-chain counter for
    // monitoring/alerting on write-offs (the per-loan BadDebtRealized event still fires).
    uint256 public totalBadDebtRealized;
    bool public borrowPaused = true;
    address public settlementSigner;
    mapping(uint256 nonce => bool used) public usedSettlementNonces;
    mapping(uint256 loanId => bool issued) public loanIssued;

    bytes32 public constant LOSS_SETTLEMENT_TYPEHASH = keccak256(
        "LossSettlement(uint256 loanId,address wallet,uint256 amount,uint256 maxWriteOff,uint256 nonce,uint256 deadline)"
    );
    bytes32 private constant REPAY_WALLET_SLOT = keccak256("amplifi.repay.wallet");
    bytes32 private constant REPAY_LOAN_SLOT = keccak256("amplifi.repay.loan");
    bytes32 private constant REPAY_BALANCE_SLOT = keccak256("amplifi.repay.balance");

    struct Payment {
        address wallet;
        uint256 credited;
        uint256 interestPaid;
        uint256 principalPaid;
        uint256 burnedShares;
    }

    // ── Constants ───────────────────────────────────────────────────────
    uint256 private constant BPS = 10_000;
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant RAY = 1e27;
    // Hard ceiling on maxRateBps (10,000% APR). Prevents the rate-spike drain path
    // where an owner with one share inflates totalBorrowAssets, rounds withdraw share
    // cost down to 1, and burns 1 share for the whole pool.
    uint256 public constant MAX_RATE_CAP_BPS = 1_000_000;
    uint256 public constant MAX_FEE_BPS = 5_000;
    // Virtual offset to mitigate ERC-4626 first-depositor inflation attack.
    // See: https://docs.openzeppelin.com/contracts/5.x/erc4626#defending_with_a_virtual_offset
    uint256 private constant VIRTUAL_SHARES = 1e3;
    uint256 private constant VIRTUAL_ASSETS = 1e3;

    // ── Events ──────────────────────────────────────────────────────────
    // Deposit and Withdraw events are inherited from IERC4626 (with sender/owner/receiver).
    event Borrow(uint256 indexed loanId, address indexed wallet, uint256 amount, uint256 shares);
    event Repay(uint256 indexed loanId, address indexed wallet, uint256 repaid, uint256 shares);
    event BadDebtRealized(uint256 indexed loanId, uint256 badDebt);
    event RepaymentApplied(
        uint256 indexed loanId,
        address indexed wallet,
        uint256 received,
        uint256 principalPaid,
        uint256 interestPaid,
        uint256 remainingPrincipal,
        uint256 remainingDebt
    );
    event RepaymentRefunded(uint256 indexed loanId, address indexed wallet, uint256 amount);
    event LoanWrittenOff(
        uint256 indexed loanId, uint256 principalWrittenOff, uint256 interestWrittenOff, uint256 remainingDebt
    );
    event SettlementSignerUpdated(address indexed signer);
    event BorrowPausedUpdated(bool paused);
    event DebtRoundingAdjustment(uint256 indexed loanId, uint256 amount);
    event InterestAccrued(uint256 interest, uint256 newTotalBorrowAssets);
    event TeeOperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event RateParamsUpdated(uint256 baseRateBps, uint256 kinkUtilizationBps, uint256 kinkRateBps, uint256 maxRateBps);
    event PoolStatusUpdated(PoolStatus oldStatus, PoolStatus newStatus);
    event BorrowAllowlistEnabledUpdated(bool enabled);
    event AllowedBorrowerWalletUpdated(address indexed wallet, bool allowed);
    event DepositorWhitelistUpdated(address indexed depositor, bool whitelisted);
    event BorrowCapsUpdated(uint256 maxBorrowPerLoan, uint256 maxBorrowPerWindow, uint256 borrowWindow);
    event ProtocolFeeUpdated(uint256 feeBps);
    event FeeRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event ProtocolFeeAccrued(uint256 indexed loanId, uint256 interest, uint256 fee);
    event ProtocolFeesCollected(address indexed to, uint256 amount);

    // ── Errors ──────────────────────────────────────────────────────────
    error OnlyTeeOperator();
    error BorrowPaused();
    error RepaymentInProgress();
    error RepaymentNotStarted();
    error RepaymentAmountMismatch();
    error RepaymentTooSmall();
    error InsufficientRepayment();
    error InvalidSettlementPermit();
    error WriteOffLimitExceeded();
    error OnlyBorrowerWallet();
    error PoolNotActive();
    error InsufficientLiquidity();
    error ZeroAmount();
    error ZeroShares();
    error InvalidRateParams();
    error InvalidStatusTransition();
    error LoanAlreadyExists();
    error LoanNotFound();
    error WalletNotAllowed();
    error DepositorNotWhitelisted();
    error BorrowCapExceeded();
    error InvalidBorrowCaps();
    error InvalidFeeParams();
    error OnlyOwnerOrFeeRecipient();
    error FeeExceedsAccrued();

    // ── Modifiers ───────────────────────────────────────────────────────
    modifier noActiveRepayment() {
        if (_transientRead(REPAY_WALLET_SLOT) != 0) revert RepaymentInProgress();
        _;
    }

    modifier onlyTeeOperator() {
        if (msg.sender != teeOperator) revert OnlyTeeOperator();
        _;
    }

    modifier whenActive() {
        if (status != PoolStatus.Active) revert PoolNotActive();
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────────
    constructor(
        address _usdc,
        address _owner,
        address _teeOperator,
        uint256 _baseRateBps,
        uint256 _kinkUtilizationBps,
        uint256 _kinkRateBps,
        uint256 _maxRateBps,
        address[] memory _depositors
    ) ERC20(shareName(_usdc), shareSymbol(_usdc)) Ownable(_owner) EIP712("AmplifiLendingPool", "2") {
        // A zero asset already reverted in shareName, before this body ran.
        if (_teeOperator == address(0)) revert ZeroAddress();
        usdc = IERC20(_usdc);
        SHARE_DECIMALS = IERC20Metadata(_usdc).decimals();
        teeOperator = _teeOperator;
        baseRateBps = _baseRateBps;
        kinkUtilizationBps = _kinkUtilizationBps;
        kinkRateBps = _kinkRateBps;
        maxRateBps = _maxRateBps;
        lastAccrualTimestamp = block.timestamp;

        _validateRateParams(_baseRateBps, _kinkUtilizationBps, _kinkRateBps, _maxRateBps);

        uint256 len = _depositors.length;
        for (uint256 i; i < len; ++i) {
            _setDepositorWhitelisted(_depositors[i], true);
        }
    }

    // ── ERC20 / IERC20Metadata Override ─────────────────────────────────
    function decimals() public view override(ERC20, IERC20Metadata) returns (uint8) {
        return SHARE_DECIMALS;
    }

    // ── ERC-4626 ────────────────────────────────────────────────────────

    function asset() external view returns (address) {
        return address(usdc);
    }

    // ── Deposits ────────────────────────────────────────────────────────

    /// @notice 1-arg convenience wrapper. Mints shares to msg.sender.
    function deposit(uint256 assets) external returns (uint256 shares) {
        return deposit(assets, msg.sender);
    }

    function deposit(uint256 assets, address receiver)
        public
        nonReentrant
        noActiveRepayment
        whenActive
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        _checkDepositor(msg.sender, receiver);
        accrueInterest();

        shares = assetsToShares(assets);
        if (shares == 0) revert ZeroShares();

        usdc.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver)
        external
        nonReentrant
        noActiveRepayment
        whenActive
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();
        _checkDepositor(msg.sender, receiver);
        accrueInterest();

        assets = previewMint(shares);
        if (assets == 0) revert ZeroAmount();

        usdc.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    // ── Withdrawals ─────────────────────────────────────────────────────
    // Withdraw / redeem / repay are NOT gated by PoolStatus.Closed. Gating them
    // would let a careless or malicious setPoolStatus(Closed) permanently strand
    // lender funds and outstanding loans (audit #1, #6).

    /// @notice Redeem by SHARES. Burns `shares` from msg.sender and sends the corresponding
    ///         assets to msg.sender. WARNING: this overload takes SHARES, NOT assets, it is
    ///         NOT the ERC-4626 `withdraw(assets,...)`. To withdraw a specific ASSET amount use
    ///         `withdrawAssets(assets)` or the 3-arg `withdraw(assets, receiver, owner)`.
    function withdraw(uint256 shares) external nonReentrant noActiveRepayment returns (uint256 assets) {
        if (shares == 0) revert ZeroShares();
        accrueInterest();

        assets = sharesToAssets(shares);
        if (assets == 0) revert ZeroAmount();
        if (assets > availableLiquidity()) revert InsufficientLiquidity();

        _burn(msg.sender, shares);
        usdc.safeTransfer(msg.sender, assets);

        emit Withdraw(msg.sender, msg.sender, msg.sender, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address _owner)
        external
        nonReentrant
        noActiveRepayment
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        accrueInterest();

        if (assets > availableLiquidity()) revert InsufficientLiquidity();

        shares = previewWithdraw(assets);
        if (shares == 0) revert ZeroShares();

        if (_owner != msg.sender) {
            _spendAllowance(_owner, msg.sender, shares);
        }
        _burn(_owner, shares);
        usdc.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, _owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address _owner)
        external
        nonReentrant
        noActiveRepayment
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroShares();
        if (receiver == address(0)) revert ZeroAddress();
        accrueInterest();

        assets = sharesToAssets(shares);
        if (assets == 0) revert ZeroAmount();
        if (assets > availableLiquidity()) revert InsufficientLiquidity();

        if (_owner != msg.sender) {
            _spendAllowance(_owner, msg.sender, shares);
        }
        _burn(_owner, shares);
        usdc.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, _owner, assets, shares);
    }

    /// @notice Backward-compat. Takes assets, burns shares from msg.sender, sends to msg.sender.
    function withdrawAssets(uint256 assets) external nonReentrant noActiveRepayment returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();
        accrueInterest();

        if (assets > availableLiquidity()) revert InsufficientLiquidity();

        shares = previewWithdraw(assets);
        if (shares == 0) revert ZeroShares();

        _burn(msg.sender, shares);
        usdc.safeTransfer(msg.sender, assets);

        emit Withdraw(msg.sender, msg.sender, msg.sender, assets, shares);
    }

    // ── Borrow / Repay ──────────────────────────────────────────────────

    /// @notice Open a loan, disbursing the principal directly to `wallet` (the
    ///         borrower's deposit wallet). That same wallet later repays by pushing
    ///         the repayment to this pool and calling repay() (see repay()). Caller
    ///         (teeOperator) is trusted to pass the wallet that posted collateral for
    ///         this loan.
    function borrow(uint256 loanId, uint256 amount, address wallet)
        external
        nonReentrant
        noActiveRepayment
        onlyTeeOperator
        whenActive
    {
        if (borrowPaused) revert BorrowPaused();
        if (amount == 0) revert ZeroAmount();
        if (wallet == address(0)) revert ZeroAddress();
        if (loanIssued[loanId]) revert LoanAlreadyExists();

        _enforceBorrowControls(wallet, amount);

        accrueInterest();

        if (amount > availableLiquidity()) revert InsufficientLiquidity();

        uint256 shares = _borrowSharesToMint(amount);
        loanIssued[loanId] = true;
        loanShares[loanId] = shares;
        loanWallet[loanId] = wallet;
        loanPrincipal[loanId] = amount;
        totalBorrowShares += shares;
        uint256 previousAssets = totalBorrowAssets;
        totalBorrowAssets = _debtAtIndex(totalBorrowShares, borrowIndex);
        uint256 roundingGain = totalBorrowAssets - previousAssets - amount;
        if (roundingGain != 0) emit DebtRoundingAdjustment(loanId, roundingGain);

        usdc.safeTransfer(wallet, amount);

        emit Borrow(loanId, wallet, amount, shares);
    }

    function repaymentVersion() external pure returns (uint256) {
        return 2;
    }

    /// @notice First call in the wallet's atomic [begin, transfer, repay] batch.
    function beginRepay(uint256 loanId) external nonReentrant noActiveRepayment {
        if (loanShares[loanId] == 0) revert LoanNotFound();
        if (msg.sender != loanWallet[loanId]) revert OnlyBorrowerWallet();
        accrueInterest();
        _transientWrite(REPAY_WALLET_SLOT, uint256(uint160(msg.sender)));
        _transientWrite(REPAY_LOAN_SLOT, loanId);
        _transientWrite(REPAY_BALANCE_SLOT, usdc.balanceOf(address(this)));
    }

    /// @notice Credit received funds, interest first; an unpaid balance stays open.
    function repay(uint256 loanId, uint256 amount) external nonReentrant returns (uint256 remainingDebt) {
        if (amount == 0) revert ZeroAmount();
        _verifyRepayment(loanId, amount);
        remainingDebt = _applyRepayment(loanId, amount);
    }

    /// @notice A close must remain fully funded when mined; excess is refunded.
    function repayFull(uint256 loanId, uint256 amount) external nonReentrant returns (uint256 remainingDebt) {
        _verifyRepayment(loanId, amount);
        if (amount < _borrowAssetsOwed(loanShares[loanId])) revert InsufficientRepayment();
        remainingDebt = _applyRepayment(loanId, amount);
    }

    function settleLoss(
        uint256 loanId,
        uint256 amount,
        uint256 maxWriteOff,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        _verifyRepayment(loanId, amount);
        _authorizeLossSettlement(loanId, amount, maxWriteOff, nonce, deadline, signature);
        _settleAuthorizedLoss(loanId, amount, maxWriteOff);
    }

    function _authorizeLossSettlement(
        uint256 loanId,
        uint256 amount,
        uint256 maxWriteOff,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) internal {
        if (
            block.timestamp > deadline || usedSettlementNonces[nonce] || settlementSigner == address(0)
                || settlementSigner == msg.sender
        ) revert InvalidSettlementPermit();
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(LOSS_SETTLEMENT_TYPEHASH, loanId, msg.sender, amount, maxWriteOff, nonce, deadline))
        );
        if (ECDSA.recover(digest, signature) != settlementSigner) revert InvalidSettlementPermit();
        usedSettlementNonces[nonce] = true;
    }

    function _settleAuthorizedLoss(uint256 loanId, uint256 amount, uint256 maxWriteOff) internal {
        uint256 debt = _borrowAssetsOwed(loanShares[loanId]);
        if (amount >= debt) {
            _applyRepayment(loanId, amount);
        } else {
            if (debt - amount > maxWriteOff) revert WriteOffLimitExceeded();
            _settleLoss(loanId, amount, debt);
        }
    }

    /// @notice Exceptional loss recognition when the recorded borrower cannot settle.
    function writeOff(uint256 loanId, uint256 maxWriteOff) external onlyOwner nonReentrant noActiveRepayment {
        if (loanShares[loanId] == 0) revert LoanNotFound();
        accrueInterest();
        uint256 debt = _borrowAssetsOwed(loanShares[loanId]);
        if (debt > maxWriteOff) revert WriteOffLimitExceeded();
        _writeOff(loanId, debt);
    }

    function _verifyRepayment(uint256 loanId, uint256 amount) internal {
        if (loanShares[loanId] == 0) revert LoanNotFound();
        if (msg.sender != loanWallet[loanId]) revert OnlyBorrowerWallet();
        if (
            _transientRead(REPAY_WALLET_SLOT) != uint256(uint160(msg.sender))
                || _transientRead(REPAY_LOAN_SLOT) != loanId
        ) revert RepaymentNotStarted();
        uint256 balance = usdc.balanceOf(address(this));
        uint256 beforeBalance = _transientRead(REPAY_BALANCE_SLOT);
        if (balance < beforeBalance || balance - beforeBalance != amount) revert RepaymentAmountMismatch();
        _transientWrite(REPAY_WALLET_SLOT, 0);
        _transientWrite(REPAY_LOAN_SLOT, 0);
        _transientWrite(REPAY_BALANCE_SLOT, 0);
    }

    function _applyRepayment(uint256 loanId, uint256 received) internal returns (uint256 remainingDebt) {
        uint256 shares = loanShares[loanId];
        uint256 debt = _borrowAssetsOwed(shares);
        Payment memory payment;
        payment.wallet = loanWallet[loanId];
        payment.credited = Math.min(received, debt);
        if (payment.credited != 0 && payment.credited < debt) {
            payment.burnedShares = Math.mulDiv(payment.credited, RAY, borrowIndex);
            if (payment.burnedShares == 0) revert RepaymentTooSmall();
            payment.credited = _debtAtIndex(payment.burnedShares, borrowIndex);
        }
        payment.interestPaid = Math.min(payment.credited, debt - loanPrincipal[loanId]);
        payment.principalPaid = payment.credited - payment.interestPaid;
        if (payment.credited == debt) {
            payment.burnedShares = shares;
            delete loanShares[loanId];
            delete loanWallet[loanId];
            delete loanPrincipal[loanId];
        } else if (payment.credited != 0) {
            loanShares[loanId] -= payment.burnedShares;
            loanPrincipal[loanId] -= payment.principalPaid;
        }
        totalBorrowShares -= payment.burnedShares;
        {
            uint256 previousAssets = totalBorrowAssets;
            totalBorrowAssets = _debtAtIndex(totalBorrowShares, borrowIndex);
            uint256 roundingGain = payment.credited - (previousAssets - totalBorrowAssets);
            if (roundingGain != 0) emit DebtRoundingAdjustment(loanId, roundingGain);
        }
        if (totalBorrowShares == 0) borrowIndex = RAY;
        if (loanShares[loanId] != 0) remainingDebt = _borrowAssetsOwed(loanShares[loanId]);
        if (payment.interestPaid != 0 && feeBps != 0) {
            uint256 fee = Math.mulDiv(payment.interestPaid, feeBps, BPS);
            protocolFeesAccrued += fee;
            emit ProtocolFeeAccrued(loanId, payment.interestPaid, fee);
        }
        emit Repay(loanId, payment.wallet, payment.credited, payment.burnedShares);
        emit RepaymentApplied(
            loanId,
            payment.wallet,
            payment.credited,
            payment.principalPaid,
            payment.interestPaid,
            loanPrincipal[loanId],
            remainingDebt
        );
        if (received > payment.credited) {
            uint256 refund = received - payment.credited;
            usdc.safeTransfer(payment.wallet, refund);
            emit RepaymentRefunded(loanId, payment.wallet, refund);
        }
    }

    function _writeOff(uint256 loanId, uint256 debt) internal {
        uint256 principal = loanPrincipal[loanId];
        totalBorrowShares -= loanShares[loanId];
        uint256 previousAssets = totalBorrowAssets;
        totalBorrowAssets = _debtAtIndex(totalBorrowShares, borrowIndex);
        uint256 roundingGain = debt - (previousAssets - totalBorrowAssets);
        if (roundingGain != 0) emit DebtRoundingAdjustment(loanId, roundingGain);
        if (totalBorrowShares == 0) borrowIndex = RAY;
        totalBadDebtRealized += debt;
        delete loanShares[loanId];
        delete loanWallet[loanId];
        delete loanPrincipal[loanId];
        emit BadDebtRealized(loanId, debt);
        emit LoanWrittenOff(loanId, principal, debt - principal, 0);
    }

    function _settleLoss(uint256 loanId, uint256 received, uint256 debt) internal {
        address wallet = loanWallet[loanId];
        uint256 interestPaid = Math.min(received, debt - loanPrincipal[loanId]);
        uint256 principalPaid = received - interestPaid;
        uint256 remainingPrincipal = loanPrincipal[loanId] - principalPaid;
        uint256 loss = debt - received;
        uint256 shares = loanShares[loanId];
        uint256 previousAssets = totalBorrowAssets;
        totalBorrowShares -= shares;
        totalBorrowAssets = _debtAtIndex(totalBorrowShares, borrowIndex);
        uint256 roundingGain = debt - (previousAssets - totalBorrowAssets);
        if (roundingGain != 0) emit DebtRoundingAdjustment(loanId, roundingGain);
        if (totalBorrowShares == 0) borrowIndex = RAY;
        totalBadDebtRealized += loss;
        delete loanShares[loanId];
        delete loanWallet[loanId];
        delete loanPrincipal[loanId];
        emit Repay(loanId, wallet, received, shares);
        emit RepaymentApplied(loanId, wallet, received, principalPaid, interestPaid, remainingPrincipal, loss);
        emit BadDebtRealized(loanId, loss);
        emit LoanWrittenOff(loanId, remainingPrincipal, loss - remainingPrincipal, 0);
    }

    function _transientRead(bytes32 slot) internal view returns (uint256 value) {
        assembly { value := tload(slot) }
    }

    function _transientWrite(bytes32 slot, uint256 value) internal {
        assembly { tstore(slot, value) }
    }

    // ── Interest ────────────────────────────────────────────────────────

    function accrueInterest() public {
        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        if (elapsed == 0) return;

        uint256 nextIndex = _pendingBorrowIndex();
        lastAccrualTimestamp = block.timestamp;
        uint256 nextAssets = _debtAtIndex(totalBorrowShares, nextIndex);
        uint256 interest = nextAssets - totalBorrowAssets;
        borrowIndex = nextIndex;
        totalBorrowAssets = nextAssets;
        if (interest > 0) {
            emit InterestAccrued(interest, totalBorrowAssets);
        }
    }

    function borrowRate() public view returns (uint256) {
        return _borrowRateAtUtilization(utilization());
    }

    // ── View Functions ──────────────────────────────────────────────────

    function totalBorrowed() external view returns (uint256) {
        return totalBorrowAssets + _pendingInterest();
    }

    function loanDebt(uint256 loanId) external view returns (uint256) {
        uint256 shares = loanShares[loanId];
        if (shares == 0) return 0;
        return _debtAtIndex(shares, _pendingBorrowIndex());
    }

    function totalAssets() public view returns (uint256) {
        uint256 gross = usdc.balanceOf(address(this)) + totalBorrowAssets + _pendingInterest();
        return gross > protocolFeesAccrued ? gross - protocolFeesAccrued : 0;
    }

    function availableLiquidity() public view returns (uint256) {
        uint256 bal = usdc.balanceOf(address(this));
        return bal > protocolFeesAccrued ? bal - protocolFeesAccrued : 0;
    }

    function utilization() public view returns (uint256) {
        if (totalBorrowAssets == 0) return 0;

        // Estimate pending interest using the last-accrued utilization-derived rate.
        // This avoids borrowRate() <-> _pendingInterest() recursion while keeping
        // utilization aligned with outstanding debt including unaccrued interest.
        uint256 baseUtil = _utilizationWithBorrowAssets(totalBorrowAssets);
        uint256 baseRate = _borrowRateAtUtilization(baseUtil);
        uint256 adjustedBorrowAssets = totalBorrowAssets + _pendingInterestAtRate(baseRate);
        return _utilizationWithBorrowAssets(adjustedBorrowAssets);
    }

    function sharesToAssets(uint256 shares) public view returns (uint256) {
        return (shares * (totalAssets() + VIRTUAL_ASSETS)) / (totalSupply() + VIRTUAL_SHARES);
    }

    function assetsToShares(uint256 assets) public view returns (uint256) {
        return (assets * (totalSupply() + VIRTUAL_SHARES)) / (totalAssets() + VIRTUAL_ASSETS);
    }

    // ── ERC-4626 View Functions ──────────────────────────────────────────

    function maxDeposit(address receiver) external view returns (uint256) {
        return status == PoolStatus.Active && _canDeposit(receiver) ? type(uint256).max : 0;
    }

    function maxMint(address receiver) external view returns (uint256) {
        return status == PoolStatus.Active && _canDeposit(receiver) ? type(uint256).max : 0;
    }

    function maxWithdraw(address _owner) external view returns (uint256) {
        uint256 ownerAssets = sharesToAssets(balanceOf(_owner));
        uint256 liquidity = availableLiquidity();
        return ownerAssets < liquidity ? ownerAssets : liquidity;
    }

    function maxRedeem(address _owner) external view returns (uint256) {
        uint256 ownerShares = balanceOf(_owner);
        uint256 liquidityShares = assetsToShares(availableLiquidity());
        return ownerShares < liquidityShares ? ownerShares : liquidityShares;
    }

    function previewDeposit(uint256 assets) external view returns (uint256) {
        return assetsToShares(assets);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        // Round UP (favors pool): assets = ceil(shares * (totalAssets + VA) / (totalSupply + VS))
        uint256 supplyAndVirtual = totalSupply() + VIRTUAL_SHARES;
        return (shares * (totalAssets() + VIRTUAL_ASSETS) + supplyAndVirtual - 1) / supplyAndVirtual;
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        // Round UP (favors pool)
        uint256 totalAndVirtual = totalAssets() + VIRTUAL_ASSETS;
        return (assets * (totalSupply() + VIRTUAL_SHARES) + totalAndVirtual - 1) / totalAndVirtual;
    }

    function previewRedeem(uint256 shares) external view returns (uint256) {
        return sharesToAssets(shares);
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return assetsToShares(assets);
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return sharesToAssets(shares);
    }

    // ── Admin Functions ─────────────────────────────────────────────────

    function setSettlementSigner(address signer) external onlyOwner {
        settlementSigner = signer;
        emit SettlementSignerUpdated(signer);
    }

    function setBorrowPaused(bool paused) external onlyOwner {
        borrowPaused = paused;
        emit BorrowPausedUpdated(paused);
    }

    function setTeeOperator(address _teeOperator) external onlyOwner {
        if (_teeOperator == address(0)) revert ZeroAddress();
        emit TeeOperatorUpdated(teeOperator, _teeOperator);
        teeOperator = _teeOperator;
    }

    function setRateParams(uint256 _baseRateBps, uint256 _kinkUtilizationBps, uint256 _kinkRateBps, uint256 _maxRateBps)
        external
        virtual
        onlyOwner
    {
        _setRateParams(_baseRateBps, _kinkUtilizationBps, _kinkRateBps, _maxRateBps);
    }

    function _setRateParams(
        uint256 _baseRateBps,
        uint256 _kinkUtilizationBps,
        uint256 _kinkRateBps,
        uint256 _maxRateBps
    ) internal virtual {
        _validateRateParams(_baseRateBps, _kinkUtilizationBps, _kinkRateBps, _maxRateBps);
        accrueInterest();
        baseRateBps = _baseRateBps;
        kinkUtilizationBps = _kinkUtilizationBps;
        kinkRateBps = _kinkRateBps;
        maxRateBps = _maxRateBps;
        emit RateParamsUpdated(_baseRateBps, _kinkUtilizationBps, _kinkRateBps, _maxRateBps);
    }

    function setPoolStatus(PoolStatus _status) external onlyOwner {
        if (uint8(_status) <= uint8(status)) revert InvalidStatusTransition();
        emit PoolStatusUpdated(status, _status);
        status = _status;
    }

    /// @notice Toggle the borrower-wallet allowlist. When enabled, borrow() reverts unless
    ///         the target wallet is in `allowedBorrowerWallet`. Manage the list with a colder
    ///         key than the teeOperator for the allowlist to constrain a hot-key compromise.
    function setBorrowAllowlistEnabled(bool enabled) external onlyOwner {
        borrowAllowlistEnabled = enabled;
        emit BorrowAllowlistEnabledUpdated(enabled);
    }

    function setAllowedBorrowerWallet(address wallet, bool allowed) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        allowedBorrowerWallet[wallet] = allowed;
        emit AllowedBorrowerWalletUpdated(wallet, allowed);
    }

    /// @notice Batch variant of setAllowedBorrowerWallet, set the same `allowed` flag for many wallets.
    function setAllowedBorrowerWallets(address[] calldata wallets, bool allowed) external onlyOwner {
        uint256 len = wallets.length;
        for (uint256 i; i < len; ++i) {
            if (wallets[i] == address(0)) revert ZeroAddress();
            allowedBorrowerWallet[wallets[i]] = allowed;
            emit AllowedBorrowerWalletUpdated(wallets[i], allowed);
        }
    }

    /// @notice Add or remove a depositor. Removing the last one reopens deposits to anyone.
    function setDepositorWhitelisted(address depositor, bool whitelisted) external onlyOwner {
        _setDepositorWhitelisted(depositor, whitelisted);
    }

    /// @notice Batch variant of setDepositorWhitelisted.
    function setDepositorsWhitelisted(address[] calldata depositors, bool whitelisted) external onlyOwner {
        uint256 len = depositors.length;
        for (uint256 i; i < len; ++i) {
            _setDepositorWhitelisted(depositors[i], whitelisted);
        }
    }

    /// @notice Set the borrow circuit breakers. `_maxBorrowPerLoan` caps a single borrow;
    ///         `_maxBorrowPerWindow` caps cumulative borrows inside a rolling `_borrowWindow`
    ///         (seconds). Any of the caps set to 0 disables that check. Resets the running
    ///         window. Reverts if a window cap is set without a positive window length.
    function setBorrowCaps(uint256 _maxBorrowPerLoan, uint256 _maxBorrowPerWindow, uint256 _borrowWindow)
        external
        onlyOwner
    {
        if (_maxBorrowPerWindow != 0 && _borrowWindow == 0) revert InvalidBorrowCaps();
        maxBorrowPerLoan = _maxBorrowPerLoan;
        maxBorrowPerWindow = _maxBorrowPerWindow;
        borrowWindow = _borrowWindow;
        windowStart = block.timestamp;
        windowBorrowed = 0;
        emit BorrowCapsUpdated(_maxBorrowPerLoan, _maxBorrowPerWindow, _borrowWindow);
    }

    function setProtocolFee(uint256 _feeBps) external onlyOwner {
        _setProtocolFee(_feeBps);
    }

    function _setProtocolFee(uint256 _feeBps) internal {
        if (_feeBps > MAX_FEE_BPS) revert InvalidFeeParams();
        feeBps = _feeBps;
        emit ProtocolFeeUpdated(_feeBps);
    }

    function setFeeRecipient(address _feeRecipient) external onlyOwner {
        emit FeeRecipientUpdated(feeRecipient, _feeRecipient);
        feeRecipient = _feeRecipient;
    }

    function collectProtocolFees(address to, uint256 amount) external nonReentrant noActiveRepayment {
        if (msg.sender != owner() && msg.sender != feeRecipient) revert OnlyOwnerOrFeeRecipient();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > protocolFeesAccrued) revert FeeExceedsAccrued();
        accrueInterest();
        protocolFeesAccrued -= amount;
        usdc.safeTransfer(to, amount);
        emit ProtocolFeesCollected(to, amount);
    }

    // ── Internal ────────────────────────────────────────────────────────

    function _setDepositorWhitelisted(address depositor, bool whitelisted) internal {
        if (depositor == address(0)) revert ZeroAddress();
        if (isDepositorWhitelisted[depositor] != whitelisted) {
            isDepositorWhitelisted[depositor] = whitelisted;
            if (whitelisted) ++depositorWhitelistCount;
            else --depositorWhitelistCount;
        }
        emit DepositorWhitelistUpdated(depositor, whitelisted);
    }

    function _canDeposit(address account) internal view returns (bool) {
        return depositorWhitelistCount == 0 || isDepositorWhitelisted[account];
    }

    /// @dev Both the funder and the share receiver must be whitelisted, so no outside
    ///      address gains shares through a deposit.
    function _checkDepositor(address caller, address receiver) internal view {
        if (!_canDeposit(caller) || !_canDeposit(receiver)) revert DepositorNotWhitelisted();
    }

    /// @dev Enforce the OWNER-configured borrow controls (allowlist + per-loan cap + rolling
    ///      window cap). All checks are no-ops until an owner sets them. On the window cap this
    ///      advances the tumbling window and accumulates `windowBorrowed`; a later revert in
    ///      borrow() rolls that back with the rest of the tx.
    function _enforceBorrowControls(address wallet, uint256 amount) internal {
        if (borrowAllowlistEnabled && !allowedBorrowerWallet[wallet]) revert WalletNotAllowed();
        if (maxBorrowPerLoan != 0 && amount > maxBorrowPerLoan) revert BorrowCapExceeded();
        if (maxBorrowPerWindow != 0) {
            if (block.timestamp >= windowStart + borrowWindow) {
                windowStart = block.timestamp;
                windowBorrowed = 0;
            }
            if (windowBorrowed + amount > maxBorrowPerWindow) revert BorrowCapExceeded();
            windowBorrowed += amount;
        }
    }

    /// @dev Convert borrow assets to shares. Rounds UP (favors protocol on borrow).
    function _borrowSharesToMint(uint256 assets) internal view returns (uint256) {
        return Math.mulDiv(assets, RAY, borrowIndex, Math.Rounding.Ceil);
    }

    /// @dev Loan debt uses a monotonic index so another loan's payment cannot reduce it.
    function _borrowAssetsOwed(uint256 shares) internal view returns (uint256) {
        return _debtAtIndex(shares, borrowIndex);
    }

    function _pendingInterest() internal view returns (uint256) {
        return _debtAtIndex(totalBorrowShares, _pendingBorrowIndex()) - totalBorrowAssets;
    }

    function _pendingInterestAtRate(uint256 rate) internal view returns (uint256) {
        return _debtAtIndex(totalBorrowShares, _indexAtRate(rate)) - totalBorrowAssets;
    }

    function _pendingBorrowIndex() internal view returns (uint256) {
        return _indexAtRate(_borrowRateAtUtilization(_utilizationWithBorrowAssets(totalBorrowAssets)));
    }

    function _indexAtRate(uint256 rate) internal view returns (uint256) {
        if (totalBorrowShares == 0) return borrowIndex;
        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        return borrowIndex + Math.mulDiv(borrowIndex, rate * elapsed, BPS * SECONDS_PER_YEAR);
    }

    function _debtAtIndex(uint256 shares, uint256 index) internal pure returns (uint256) {
        return Math.mulDiv(shares, index, RAY, Math.Rounding.Ceil);
    }

    function _utilizationWithBorrowAssets(uint256 borrowAssets) internal view returns (uint256) {
        uint256 total = usdc.balanceOf(address(this)) + borrowAssets;
        if (total == 0) return 0;
        return (borrowAssets * BPS) / total;
    }

    function _borrowRateAtUtilization(uint256 util) internal view returns (uint256) {
        if (util <= kinkUtilizationBps) {
            // Below kink: linear from baseRate to kinkRate
            if (kinkUtilizationBps == 0) return baseRateBps;
            return baseRateBps + ((kinkRateBps - baseRateBps) * util) / kinkUtilizationBps;
        }

        // Above kink: linear from kinkRate to maxRate
        uint256 excessUtil = util - kinkUtilizationBps;
        uint256 excessRange = BPS - kinkUtilizationBps;
        if (excessRange == 0) return maxRateBps;
        return kinkRateBps + ((maxRateBps - kinkRateBps) * excessUtil) / excessRange;
    }

    function _validateRateParams(
        uint256 _baseRateBps,
        uint256 _kinkUtilizationBps,
        uint256 _kinkRateBps,
        uint256 _maxRateBps
    ) internal pure {
        if (_baseRateBps > _kinkRateBps) revert InvalidRateParams();
        if (_kinkRateBps > _maxRateBps) revert InvalidRateParams();
        if (_maxRateBps > MAX_RATE_CAP_BPS) revert InvalidRateParams();
        if (_kinkUtilizationBps == 0 || _kinkUtilizationBps > BPS) revert InvalidRateParams();
    }
}
