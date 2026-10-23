// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title CollateralEscrow
/// @notice Holds user collateral released only against EIP-712 withdrawal attestations signed by
///         amplifi-controlled attester keys. Seizures are deliberately unsupported.
///         Spec: amplifi docs/collateral-escrow-attestation.md. Per-account balances are
///         informational accounting (clamped at zero, never a release ceiling): the contract may
///         hold a protocol-funded cushion (see fundCushion) so releases can exceed a user's own
///         deposit, e.g. trading profits.
contract CollateralEscrow is EIP712, Pausable, Ownable2Step {
    using SafeERC20 for IERC20;

    // ── Structs ─────────────────────────────────────────────────────────
    struct CollateralRelease {
        address account;
        address token;
        uint256 amount;
        uint256 attestationId;
        uint256 deadline;
    }

    struct TokenCaps {
        uint256 perAttestationCap;
        uint256 dailyReleaseLimit;
        uint256 dayStart;
        uint256 releasedInDay;
    }

    // ── Constants ───────────────────────────────────────────────────────
    bytes32 public constant COLLATERAL_RELEASE_TYPEHASH = keccak256(
        "CollateralRelease(address account,address token,uint256 amount,uint256 attestationId,uint256 deadline)"
    );
    // ── State ───────────────────────────────────────────────────────────
    mapping(address account => mapping(address token => uint256)) public balances;
    mapping(uint256 attestationId => bool) public consumed;
    mapping(address => bool) public isAttester;
    mapping(address token => bool) public isCollateralAllowed;

    uint256 public maxAttestationTtl;
    mapping(address token => TokenCaps) public tokenCaps;

    // ── Events ──────────────────────────────────────────────────────────
    event CollateralDeposited(address indexed account, address indexed token, uint256 amount);
    event CollateralReleased(
        address indexed account, address indexed token, uint256 amount, uint256 indexed attestationId, address caller
    );
    event CushionFunded(address indexed funder, address indexed token, uint256 amount);
    event AttestationCancelled(uint256 indexed attestationId, address indexed attester);
    event AttesterUpdated(address indexed attester, bool allowed);
    event CollateralAllowedUpdated(address indexed token, bool allowed);
    event CapsUpdated(address indexed token, uint256 perAttestationCap, uint256 dailyReleaseLimit);
    event MaxAttestationTtlUpdated(uint256 maxAttestationTtl);

    // ── Errors ──────────────────────────────────────────────────────────
    error ZeroAmount();
    error ZeroAddress();
    error TokenNotAllowed();
    error AttestationExpired();
    error DeadlineTooFar();
    error InvalidAttester();
    error AttestationConsumed();
    error OnlyAttester();
    error PerAttestationCapExceeded();
    error DailyReleaseLimitExceeded();
    error ZeroTtl();
    error InvalidCaps();
    error OwnerIsAttester();

    constructor(
        address initialOwner,
        address collateralToken,
        address attester,
        uint256 perAttestation,
        uint256 dailyLimit,
        uint256 ttl
    ) EIP712("Amplifi", "1") Ownable(initialOwner) {
        if (collateralToken == address(0) || attester == address(0)) revert ZeroAddress();
        if (initialOwner == attester) revert OwnerIsAttester();
        if (ttl == 0) revert ZeroTtl();
        _setTokenCaps(collateralToken, perAttestation, dailyLimit);
        isCollateralAllowed[collateralToken] = true;
        isAttester[attester] = true;
        maxAttestationTtl = ttl;
        emit CollateralAllowedUpdated(collateralToken, true);
        emit AttesterUpdated(attester, true);
        emit MaxAttestationTtlUpdated(ttl);
    }

    // ── Deposits ────────────────────────────────────────────────────────

    /// @notice Deposit an allowlisted collateral token. Standard non-rebasing ERC-20s only:
    ///         the ledger assumes a transfer of `amount` credits exactly `amount`.
    function deposit(address token, uint256 amount) external whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (!isCollateralAllowed[token]) revert TokenNotAllowed();
        balances[msg.sender][token] += amount;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit CollateralDeposited(msg.sender, token, amount);
    }

    /// @notice Add token cushion held by the contract but credited to no account, so releases
    ///         (e.g. trading profits) can exceed a user's own deposit. Callable by anyone.
    function fundCushion(address token, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit CushionFunded(msg.sender, token, amount);
    }

    // ── Release (attestation-gated withdrawal) ──────────────────────────

    /// @notice Release collateral to `release.account` against an attester-signed EIP-712
    ///         CollateralRelease. msg.sender is deliberately unrestricted (anyone may relay);
    ///         funds only ever move to the attested account. The transfer draws on the
    ///         contract's whole holdings: the per-account balance is decremented clamped at
    ///         zero, and an underfunded contract reverts in the token transfer.
    function withdrawWithAttestation(CollateralRelease calldata release, bytes calldata signature)
        external
        whenNotPaused
    {
        if (release.amount == 0) revert ZeroAmount();
        if (block.timestamp > release.deadline) revert AttestationExpired();
        if (release.deadline > block.timestamp + maxAttestationTtl) revert DeadlineTooFar();
        TokenCaps storage caps = tokenCaps[release.token];
        if (caps.perAttestationCap == 0) revert TokenNotAllowed();
        if (release.amount > caps.perAttestationCap) revert PerAttestationCapExceeded();

        bytes32 structHash = keccak256(
            abi.encode(
                COLLATERAL_RELEASE_TYPEHASH,
                release.account,
                release.token,
                release.amount,
                release.attestationId,
                release.deadline
            )
        );
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), signature);
        if (!isAttester[signer]) revert InvalidAttester();

        if (consumed[release.attestationId]) revert AttestationConsumed();
        consumed[release.attestationId] = true;

        if (block.timestamp >= caps.dayStart + 1 days) {
            caps.dayStart = block.timestamp;
            caps.releasedInDay = 0;
        }
        if (caps.releasedInDay + release.amount > caps.dailyReleaseLimit) revert DailyReleaseLimitExceeded();
        caps.releasedInDay += release.amount;

        uint256 bal = balances[release.account][release.token];
        balances[release.account][release.token] = bal > release.amount ? bal - release.amount : 0;

        IERC20(release.token).safeTransfer(release.account, release.amount);
        emit CollateralReleased(release.account, release.token, release.amount, release.attestationId, msg.sender);
    }

    /// @notice Cancel a pending release so the attester can issue a corrected one.
    function cancelAttestation(uint256 attestationId) external {
        if (!isAttester[msg.sender]) revert OnlyAttester();
        if (consumed[attestationId]) revert AttestationConsumed();
        consumed[attestationId] = true;
        emit AttestationCancelled(attestationId, msg.sender);
    }

    // ── Owner admin ─────────────────────────────────────────────────────

    function acceptOwnership() public override {
        if (isAttester[msg.sender]) revert OwnerIsAttester();
        super.acceptOwnership();
    }

    function setAttester(address attester, bool allowed) external onlyOwner {
        if (attester == address(0)) revert ZeroAddress();
        if (allowed && attester == owner()) revert OwnerIsAttester();
        isAttester[attester] = allowed;
        emit AttesterUpdated(attester, allowed);
    }

    function setCollateralAllowed(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (allowed && tokenCaps[token].perAttestationCap == 0) revert InvalidCaps();
        isCollateralAllowed[token] = allowed;
        emit CollateralAllowedUpdated(token, allowed);
    }

    function setTokenCaps(address token, uint256 perAttestation, uint256 dailyLimit) external onlyOwner {
        _setTokenCaps(token, perAttestation, dailyLimit);
    }

    function _setTokenCaps(address token, uint256 perAttestation, uint256 dailyLimit) internal {
        if (token == address(0)) revert ZeroAddress();
        if (perAttestation == 0 || dailyLimit < perAttestation) revert InvalidCaps();
        TokenCaps storage caps = tokenCaps[token];
        caps.perAttestationCap = perAttestation;
        caps.dailyReleaseLimit = dailyLimit;
        emit CapsUpdated(token, perAttestation, dailyLimit);
    }

    function setMaxAttestationTtl(uint256 ttl) external onlyOwner {
        if (ttl == 0) revert ZeroTtl();
        maxAttestationTtl = ttl;
        emit MaxAttestationTtlUpdated(ttl);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
