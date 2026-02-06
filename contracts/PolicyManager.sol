// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title IInsurancePoolRegistry
/// @notice Interface for interacting with the InsurancePoolRegistry
interface IInsurancePoolRegistry {
    function reserveCapacity(uint256 poolId, uint256 amount) external;
    function releaseCapacity(uint256 poolId, uint256 amount) external;
    function recordPremium(uint256 poolId, uint256 amount) external;
    function getPoolTerms(uint256 poolId) external view returns (
        uint256 maxPayoutPerClaim,
        uint256 premiumRateBps,
        uint256 minCoveragePeriod,
        uint256 maxCoveragePeriod
    );
    function getPool(uint256 poolId) external view returns (
        address underwriter,
        uint256 totalStaked,
        uint256 availableCapacity,
        uint256 premiumsEarned,
        uint256 claimsPaid,
        bool active
    );
}

/// @title PolicyManager
/// @notice Manages policy lifecycle for SkillSure Protocol — decentralized insurance for AI agent outputs
contract PolicyManager is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Enums ---

    enum RiskTier {
        LowRisk,    // 100 bps  = 1%
        MediumRisk, // 300 bps  = 3%
        HighRisk    // 500-1000 bps = 5-10% (uses pool's premiumRateBps, clamped to range)
    }

    // --- Structs ---

    struct Policy {
        address holder;
        uint256 poolId;
        uint256 coverageAmount;
        uint256 premiumPaid;
        uint256 startTime;
        uint256 endTime;
        RiskTier riskTier;
        bool active;
        bool claimFiled;
    }

    // --- State ---

    IERC20 public immutable usdc;
    IInsurancePoolRegistry public immutable poolRegistry;

    uint256 public policyCount;
    mapping(uint256 => Policy) public policies;
    mapping(address => uint256[]) public holderPolicies;
    mapping(address => bool) public hasActiveSkillBond;

    uint256 public constant SKILLBOND_DISCOUNT_BPS = 2000; // 20% discount
    uint256 public constant LOW_RISK_BPS = 100;            // 1%
    uint256 public constant MEDIUM_RISK_BPS = 300;         // 3%
    uint256 public constant HIGH_RISK_MIN_BPS = 500;       // 5%
    uint256 public constant HIGH_RISK_MAX_BPS = 1000;      // 10%
    uint256 public constant BPS_DENOMINATOR = 10000;

    // --- Events ---

    event PolicyPurchased(
        uint256 indexed policyId,
        address indexed holder,
        uint256 indexed poolId,
        uint256 coverageAmount,
        uint256 premiumPaid,
        uint256 startTime,
        uint256 endTime,
        RiskTier riskTier
    );

    event PolicyRenewed(
        uint256 indexed policyId,
        uint256 newPremiumPaid,
        uint256 newEndTime
    );

    event PolicyExpired(uint256 indexed policyId);

    // --- Constructor ---

    constructor(address _usdc, address _poolRegistry) Ownable(msg.sender) {
        require(_usdc != address(0), "Invalid USDC address");
        require(_poolRegistry != address(0), "Invalid registry address");
        usdc = IERC20(_usdc);
        poolRegistry = IInsurancePoolRegistry(_poolRegistry);
    }

    // --- Core Functions ---

    /// @notice Purchase a new insurance policy against a specific pool
    /// @param poolId The pool to insure against
    /// @param coverageAmount The desired coverage amount in USDC
    /// @param coveragePeriod Duration in seconds
    /// @param riskTier The risk tier for premium calculation
    function buyPolicy(
        uint256 poolId,
        uint256 coverageAmount,
        uint256 coveragePeriod,
        RiskTier riskTier
    ) external nonReentrant returns (uint256 policyId) {
        require(coverageAmount > 0, "Coverage must be > 0");

        // Validate pool is active and coverage fits within pool terms
        (,,, bool poolActive) = _validatePoolTerms(poolId, coverageAmount, coveragePeriod);
        require(poolActive, "Pool inactive");

        // Calculate premium
        uint256 premium = calculatePremium(coverageAmount, poolId, riskTier, msg.sender);
        require(premium > 0, "Premium must be > 0");

        // Transfer premium from buyer to this contract, then to registry
        usdc.safeTransferFrom(msg.sender, address(poolRegistry), premium);

        // Reserve capacity in the pool
        poolRegistry.reserveCapacity(poolId, coverageAmount);
        poolRegistry.recordPremium(poolId, premium);

        // Create policy
        policyId = policyCount++;
        policies[policyId] = Policy({
            holder: msg.sender,
            poolId: poolId,
            coverageAmount: coverageAmount,
            premiumPaid: premium,
            startTime: block.timestamp,
            endTime: block.timestamp + coveragePeriod,
            riskTier: riskTier,
            active: true,
            claimFiled: false
        });

        holderPolicies[msg.sender].push(policyId);

        emit PolicyPurchased(
            policyId,
            msg.sender,
            poolId,
            coverageAmount,
            premium,
            block.timestamp,
            block.timestamp + coveragePeriod,
            riskTier
        );
    }

    /// @notice Renew an existing policy for another coverage period
    /// @param policyId The policy to renew
    /// @param coveragePeriod New coverage duration in seconds
    function renewPolicy(uint256 policyId, uint256 coveragePeriod) external nonReentrant {
        Policy storage policy = policies[policyId];
        require(policy.holder == msg.sender, "Not policy holder");
        require(policy.active, "Policy not active");
        require(!policy.claimFiled, "Claim already filed");

        // Validate pool terms for renewal
        (,,, bool poolActive) = _validatePoolTerms(policy.poolId, policy.coverageAmount, coveragePeriod);
        require(poolActive, "Pool inactive");

        // Calculate new premium
        uint256 premium = calculatePremium(
            policy.coverageAmount,
            policy.poolId,
            policy.riskTier,
            msg.sender
        );

        // Transfer premium
        usdc.safeTransferFrom(msg.sender, address(poolRegistry), premium);
        poolRegistry.recordPremium(policy.poolId, premium);

        // If policy already expired, re-reserve capacity
        if (block.timestamp >= policy.endTime) {
            poolRegistry.reserveCapacity(policy.poolId, policy.coverageAmount);
            policy.startTime = block.timestamp;
            policy.endTime = block.timestamp + coveragePeriod;
        } else {
            // Extend from current end time
            policy.endTime += coveragePeriod;
        }

        policy.premiumPaid += premium;

        emit PolicyRenewed(policyId, premium, policy.endTime);
    }

    /// @notice Expire a policy that has passed its end time, releasing reserved capacity
    /// @param policyId The policy to expire
    function expirePolicy(uint256 policyId) external {
        Policy storage policy = policies[policyId];
        require(policy.active, "Already inactive");
        require(block.timestamp >= policy.endTime, "Policy not yet expired");

        policy.active = false;

        // Release reserved capacity back to the pool if no claim was filed
        if (!policy.claimFiled) {
            poolRegistry.releaseCapacity(policy.poolId, policy.coverageAmount);
        }

        emit PolicyExpired(policyId);
    }

    /// @notice Check the current status of a policy
    /// @param policyId The policy to check
    /// @return active Whether the policy is currently active and within its coverage period
    /// @return expired Whether the policy's end time has passed
    /// @return claimFiled Whether a claim has been filed on this policy
    function checkStatus(uint256 policyId) external view returns (
        bool active,
        bool expired,
        bool claimFiled
    ) {
        Policy storage policy = policies[policyId];
        expired = block.timestamp >= policy.endTime;
        active = policy.active && !expired;
        claimFiled = policy.claimFiled;
    }

    // --- Owner Functions ---

    /// @notice Set or remove SkillBond active status for an address
    /// @param account The address to update
    /// @param isActive Whether the account has an active SkillBond stake
    function setSkillBondStatus(address account, bool isActive) external onlyOwner {
        hasActiveSkillBond[account] = isActive;
    }

    /// @notice Mark a claim as filed on a policy (called by ClaimsProcessor via owner)
    /// @param policyId The policy on which a claim is filed
    function markClaimFiled(uint256 policyId) external onlyOwner {
        Policy storage policy = policies[policyId];
        require(policy.active, "Policy not active");
        require(block.timestamp < policy.endTime, "Policy expired");
        require(!policy.claimFiled, "Claim already filed");
        policy.claimFiled = true;
    }

    // --- View Functions ---

    /// @notice Get full details of a policy
    function getPolicy(uint256 policyId) external view returns (
        address holder,
        uint256 poolId,
        uint256 coverageAmount,
        uint256 premiumPaid,
        uint256 startTime,
        uint256 endTime,
        RiskTier riskTier,
        bool active,
        bool claimFiled
    ) {
        Policy storage p = policies[policyId];
        return (
            p.holder,
            p.poolId,
            p.coverageAmount,
            p.premiumPaid,
            p.startTime,
            p.endTime,
            p.riskTier,
            p.active,
            p.claimFiled
        );
    }

    /// @notice Get all policy IDs for a holder that are currently active
    function getActivePolicies(address holder) external view returns (uint256[] memory) {
        uint256[] storage allPolicies = holderPolicies[holder];
        uint256 activeCount = 0;

        // First pass: count active policies
        for (uint256 i = 0; i < allPolicies.length; i++) {
            Policy storage p = policies[allPolicies[i]];
            if (p.active && block.timestamp < p.endTime) {
                activeCount++;
            }
        }

        // Second pass: collect active policy IDs
        uint256[] memory activePolicies = new uint256[](activeCount);
        uint256 idx = 0;
        for (uint256 i = 0; i < allPolicies.length; i++) {
            Policy storage p = policies[allPolicies[i]];
            if (p.active && block.timestamp < p.endTime) {
                activePolicies[idx++] = allPolicies[i];
            }
        }

        return activePolicies;
    }

    /// @notice Calculate the premium for a given coverage amount, pool, risk tier, and buyer
    /// @param coverageAmount The base coverage amount in USDC
    /// @param poolId The pool whose rate is used for HighRisk tier
    /// @param riskTier The risk tier
    /// @param buyer The buyer address (checked for SkillBond discount)
    /// @return premium The calculated premium in USDC
    function calculatePremium(
        uint256 coverageAmount,
        uint256 poolId,
        RiskTier riskTier,
        address buyer
    ) public view returns (uint256 premium) {
        uint256 rateBps = _getRateBps(poolId, riskTier);

        premium = (coverageAmount * rateBps) / BPS_DENOMINATOR;

        // Apply 20% SkillBond discount if buyer has an active stake
        if (hasActiveSkillBond[buyer]) {
            premium = (premium * (BPS_DENOMINATOR - SKILLBOND_DISCOUNT_BPS)) / BPS_DENOMINATOR;
        }
    }

    // --- Internal Helpers ---

    /// @dev Resolve the effective premium rate in basis points for a given risk tier
    function _getRateBps(uint256 poolId, RiskTier riskTier) internal view returns (uint256) {
        if (riskTier == RiskTier.LowRisk) {
            return LOW_RISK_BPS;
        } else if (riskTier == RiskTier.MediumRisk) {
            return MEDIUM_RISK_BPS;
        } else {
            // HighRisk: use the pool's own premiumRateBps, clamped to [500, 1000]
            (, uint256 poolRateBps,,) = poolRegistry.getPoolTerms(poolId);
            if (poolRateBps < HIGH_RISK_MIN_BPS) return HIGH_RISK_MIN_BPS;
            if (poolRateBps > HIGH_RISK_MAX_BPS) return HIGH_RISK_MAX_BPS;
            return poolRateBps;
        }
    }

    /// @dev Validate that pool terms allow the requested coverage
    function _validatePoolTerms(
        uint256 poolId,
        uint256 coverageAmount,
        uint256 coveragePeriod
    ) internal view returns (
        uint256 maxPayoutPerClaim,
        uint256 premiumRateBps,
        uint256 minCoveragePeriod,
        bool poolActive
    ) {
        uint256 maxCoveragePeriod;
        (maxPayoutPerClaim, premiumRateBps, minCoveragePeriod, maxCoveragePeriod) =
            poolRegistry.getPoolTerms(poolId);

        require(coverageAmount <= maxPayoutPerClaim, "Exceeds max payout per claim");
        require(
            coveragePeriod >= minCoveragePeriod && coveragePeriod <= maxCoveragePeriod,
            "Coverage period out of range"
        );

        (,,,,, poolActive) = poolRegistry.getPool(poolId);
    }
}
