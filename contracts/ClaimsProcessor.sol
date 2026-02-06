// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Interface for InsurancePoolRegistry claim payouts
interface IInsurancePoolRegistry {
    function payClaim(uint256 poolId, address claimant, uint256 amount) external;
}

/// @notice Interface for ValidatorRegistry
interface IValidatorRegistry {
    function isValidator(address account) external view returns (bool);
    function slash(address validator, uint256 amount) external;
    function reward(address validator, uint256 amount) external;
}

/// @title ClaimsProcessor
/// @notice Processes insurance claims for SkillSure Protocol with three-tier verification
contract ClaimsProcessor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum VerificationTier {
        Parametric,
        AIVerification,
        HumanEscalation
    }

    struct Claim {
        address claimant;
        uint256 policyId;
        uint256 poolId;
        bytes32 evidenceHash;
        uint256 requestedAmount;
        uint256 approvedAmount;
        VerificationTier tier;
        uint256 votesFor;
        uint256 votesAgainst;
        bool resolved;
        uint256 appealDeadline;
        uint256 createdAt;
    }

    struct Vote {
        address validator;
        bool approve;
        uint256 stakeAmount;
    }

    IERC20 public immutable usdc;
    IInsurancePoolRegistry public immutable poolRegistry;
    IValidatorRegistry public immutable validatorRegistry;

    uint256 public claimCount;
    mapping(uint256 => Claim) public claims;
    mapping(uint256 => Vote[]) private claimVotes;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    uint256 public constant MIN_VALIDATORS = 5;
    uint256 public constant APPEAL_WINDOW = 48 hours;
    uint256 public constant VALIDATOR_FEE_BPS = 200; // 2%

    event ClaimFiled(uint256 indexed claimId, address indexed claimant, uint256 policyId, uint256 requestedAmount);
    event ClaimValidated(uint256 indexed claimId, address indexed validator, bool approve, uint256 stakeAmount);
    event ClaimResolved(uint256 indexed claimId, bool approved, uint256 approvedAmount);
    event ClaimAppealed(uint256 indexed claimId, VerificationTier newTier);
    event ValidatorRewarded(uint256 indexed claimId, address indexed validator, uint256 reward);
    event ValidatorSlashed(uint256 indexed claimId, address indexed validator, uint256 amount);

    constructor(address _usdc, address _poolRegistry, address _validatorRegistry) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
        poolRegistry = IInsurancePoolRegistry(_poolRegistry);
        validatorRegistry = IValidatorRegistry(_validatorRegistry);
    }

    /// @notice File a new insurance claim
    /// @param policyId The policy under which the claim is filed
    /// @param evidenceHash IPFS/content hash of evidence supporting the claim
    /// @param requestedAmount Amount of USDC requested as payout
    function fileClaim(
        uint256 policyId,
        uint256 poolId,
        bytes32 evidenceHash,
        uint256 requestedAmount
    ) external returns (uint256 claimId) {
        require(requestedAmount > 0, "Amount must be > 0");
        require(evidenceHash != bytes32(0), "Evidence required");

        claimId = claimCount++;
        Claim storage c = claims[claimId];
        c.claimant = msg.sender;
        c.policyId = policyId;
        c.poolId = poolId;
        c.evidenceHash = evidenceHash;
        c.requestedAmount = requestedAmount;
        c.tier = VerificationTier.Parametric;
        c.createdAt = block.timestamp;
        c.appealDeadline = block.timestamp + APPEAL_WINDOW;

        emit ClaimFiled(claimId, msg.sender, policyId, requestedAmount);
    }

    /// @notice Validators vote on a claim by staking USDC
    /// @param claimId The claim to validate
    /// @param approve Whether the validator approves the claim
    /// @param stakeAmount Amount of USDC the validator stakes on their vote
    function validateClaim(
        uint256 claimId,
        bool approve,
        uint256 stakeAmount
    ) external nonReentrant {
        Claim storage c = claims[claimId];
        require(c.createdAt > 0, "Claim does not exist");
        require(!c.resolved, "Claim already resolved");
        require(!hasVoted[claimId][msg.sender], "Already voted");
        require(validatorRegistry.isValidator(msg.sender), "Not a validator");
        require(stakeAmount > 0, "Stake must be > 0");

        usdc.safeTransferFrom(msg.sender, address(this), stakeAmount);

        hasVoted[claimId][msg.sender] = true;
        claimVotes[claimId].push(Vote({
            validator: msg.sender,
            approve: approve,
            stakeAmount: stakeAmount
        }));

        if (approve) {
            c.votesFor++;
        } else {
            c.votesAgainst++;
        }

        emit ClaimValidated(claimId, msg.sender, approve, stakeAmount);
    }

    /// @notice Resolve a claim after enough validators have voted
    /// @param claimId The claim to resolve
    function resolveClaim(uint256 claimId) external nonReentrant {
        Claim storage c = claims[claimId];
        require(c.createdAt > 0, "Claim does not exist");
        require(!c.resolved, "Already resolved");

        uint256 totalVotes = c.votesFor + c.votesAgainst;
        require(totalVotes >= MIN_VALIDATORS, "Insufficient validators");

        c.resolved = true;
        bool approved = c.votesFor * 5 > totalVotes * 3; // 3/5 majority

        Vote[] storage votes = claimVotes[claimId];

        if (approved) {
            c.approvedAmount = c.requestedAmount;
            poolRegistry.payClaim(c.poolId, c.claimant, c.approvedAmount);
        }

        // Distribute rewards and slashing
        for (uint256 i = 0; i < votes.length; i++) {
            Vote storage v = votes[i];
            if (v.approve == approved) {
                // Honest voter: return stake + 2% fee
                uint256 reward = (v.stakeAmount * VALIDATOR_FEE_BPS) / 10000;
                usdc.safeTransfer(v.validator, v.stakeAmount + reward);
                validatorRegistry.reward(v.validator, reward);
                emit ValidatorRewarded(claimId, v.validator, reward);
            } else {
                // Dishonest voter: lose stake (slashed)
                validatorRegistry.slash(v.validator, v.stakeAmount);
                emit ValidatorSlashed(claimId, v.validator, v.stakeAmount);
            }
        }

        emit ClaimResolved(claimId, approved, c.approvedAmount);
    }

    /// @notice Appeal a claim decision, escalating to the next verification tier
    /// @param claimId The claim to appeal
    function appealClaim(uint256 claimId) external {
        Claim storage c = claims[claimId];
        require(c.createdAt > 0, "Claim does not exist");
        require(c.resolved, "Claim not yet resolved");
        require(msg.sender == c.claimant, "Only claimant can appeal");
        require(block.timestamp <= c.appealDeadline, "Appeal window expired");
        require(c.tier != VerificationTier.HumanEscalation, "Already at highest tier");

        // Escalate to next tier
        if (c.tier == VerificationTier.Parametric) {
            c.tier = VerificationTier.AIVerification;
        } else {
            c.tier = VerificationTier.HumanEscalation;
        }

        // Reset resolution state for re-voting
        c.resolved = false;
        c.votesFor = 0;
        c.votesAgainst = 0;
        c.approvedAmount = 0;
        c.appealDeadline = block.timestamp + APPEAL_WINDOW;

        // Clear previous votes and voter tracking
        Vote[] storage votes = claimVotes[claimId];
        for (uint256 i = 0; i < votes.length; i++) {
            hasVoted[claimId][votes[i].validator] = false;
        }
        delete claimVotes[claimId];

        emit ClaimAppealed(claimId, c.tier);
    }

    // --- View Functions ---

    /// @notice Get full claim details
    function getClaim(uint256 claimId) external view returns (
        address claimant,
        uint256 policyId,
        uint256 poolId,
        bytes32 evidenceHash,
        uint256 requestedAmount,
        uint256 approvedAmount,
        VerificationTier tier,
        uint256 votesFor,
        uint256 votesAgainst,
        bool resolved,
        uint256 appealDeadline,
        uint256 createdAt
    ) {
        Claim storage c = claims[claimId];
        return (
            c.claimant,
            c.policyId,
            c.poolId,
            c.evidenceHash,
            c.requestedAmount,
            c.approvedAmount,
            c.tier,
            c.votesFor,
            c.votesAgainst,
            c.resolved,
            c.appealDeadline,
            c.createdAt
        );
    }

    /// @notice Get all votes for a claim
    function getClaimVotes(uint256 claimId) external view returns (Vote[] memory) {
        return claimVotes[claimId];
    }
}
