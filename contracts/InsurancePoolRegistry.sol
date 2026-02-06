// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title InsurancePoolRegistry
/// @notice Manages underwriter pools for SkillSure Protocol
contract InsurancePoolRegistry is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct CoverageTerms {
        uint256 maxPayoutPerClaim;
        uint256 premiumRateBps; // basis points (100 = 1%)
        uint256 minCoveragePeriod;
        uint256 maxCoveragePeriod;
        string[] skillCategories;
    }

    struct Pool {
        address underwriter;
        uint256 totalStaked;
        uint256 availableCapacity;
        uint256 totalPremiumsEarned;
        uint256 totalClaimsPaid;
        uint256 createdAt;
        bool active;
        CoverageTerms terms;
    }

    IERC20 public immutable usdc;
    uint256 public poolCount;
    mapping(uint256 => Pool) public pools;
    mapping(address => uint256[]) public underwriterPools;

    uint256 public constant MIN_POOL_DEPOSIT = 1000e6; // 1,000 USDC
    uint256 public constant MAX_PREMIUM_RATE_BPS = 2000; // 20%

    event PoolCreated(uint256 indexed poolId, address indexed underwriter, uint256 deposit);
    event PoolFunded(uint256 indexed poolId, uint256 amount);
    event PoolWithdrawn(uint256 indexed poolId, uint256 amount);
    event PoolDeactivated(uint256 indexed poolId);
    event CapacityReserved(uint256 indexed poolId, uint256 amount);
    event CapacityReleased(uint256 indexed poolId, uint256 amount);
    event ClaimPaid(uint256 indexed poolId, uint256 amount);

    constructor(address _usdc) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
    }

    /// @notice Create a new insurance pool with initial USDC deposit
    function createPool(
        string calldata category,
        uint256 maxPayoutPerClaim,
        uint256 premiumRateBps,
        uint256 minCoveragePeriod,
        uint256 maxCoveragePeriod,
        uint256 depositAmount
    ) external nonReentrant returns (uint256 poolId) {
        require(depositAmount >= MIN_POOL_DEPOSIT, "Deposit below minimum");
        require(premiumRateBps > 0 && premiumRateBps <= MAX_PREMIUM_RATE_BPS, "Invalid premium rate");
        require(maxPayoutPerClaim > 0, "Invalid max payout");
        require(minCoveragePeriod > 0 && maxCoveragePeriod >= minCoveragePeriod, "Invalid coverage period");

        usdc.safeTransferFrom(msg.sender, address(this), depositAmount);

        poolId = poolCount++;
        Pool storage pool = pools[poolId];
        pool.underwriter = msg.sender;
        pool.totalStaked = depositAmount;
        pool.availableCapacity = depositAmount;
        pool.createdAt = block.timestamp;
        pool.active = true;

        string[] memory categories = new string[](1);
        categories[0] = category;
        pool.terms = CoverageTerms({
            maxPayoutPerClaim: maxPayoutPerClaim,
            premiumRateBps: premiumRateBps,
            minCoveragePeriod: minCoveragePeriod,
            maxCoveragePeriod: maxCoveragePeriod,
            skillCategories: categories
        });

        underwriterPools[msg.sender].push(poolId);

        emit PoolCreated(poolId, msg.sender, depositAmount);
    }

    /// @notice Add more USDC to an existing pool
    function fundPool(uint256 poolId, uint256 amount) external nonReentrant {
        Pool storage pool = pools[poolId];
        require(pool.underwriter == msg.sender, "Not pool owner");
        require(pool.active, "Pool inactive");

        usdc.safeTransferFrom(msg.sender, address(this), amount);
        pool.totalStaked += amount;
        pool.availableCapacity += amount;

        emit PoolFunded(poolId, amount);
    }

    /// @notice Withdraw available (unreserved) capacity from pool
    function withdraw(uint256 poolId, uint256 amount) external nonReentrant {
        Pool storage pool = pools[poolId];
        require(pool.underwriter == msg.sender, "Not pool owner");
        require(amount <= pool.availableCapacity, "Exceeds available capacity");

        pool.totalStaked -= amount;
        pool.availableCapacity -= amount;
        usdc.safeTransfer(msg.sender, amount);

        emit PoolWithdrawn(poolId, amount);
    }

    /// @notice Deactivate pool (no new policies, existing ones still valid)
    function deactivatePool(uint256 poolId) external {
        Pool storage pool = pools[poolId];
        require(pool.underwriter == msg.sender, "Not pool owner");
        pool.active = false;
        emit PoolDeactivated(poolId);
    }

    /// @notice Reserve capacity when a policy is purchased (called by PolicyManager)
    function reserveCapacity(uint256 poolId, uint256 amount) external onlyOwner {
        Pool storage pool = pools[poolId];
        require(pool.active, "Pool inactive");
        require(amount <= pool.availableCapacity, "Insufficient capacity");
        pool.availableCapacity -= amount;
        emit CapacityReserved(poolId, amount);
    }

    /// @notice Release capacity when a policy expires without claim
    function releaseCapacity(uint256 poolId, uint256 amount) external onlyOwner {
        Pool storage pool = pools[poolId];
        pool.availableCapacity += amount;
        emit CapacityReleased(poolId, amount);
    }

    /// @notice Pay out a claim from pool (called by ClaimsProcessor)
    function payClaim(uint256 poolId, address claimant, uint256 amount) external onlyOwner nonReentrant {
        Pool storage pool = pools[poolId];
        require(pool.totalStaked >= amount, "Pool underfunded");
        pool.totalStaked -= amount;
        pool.totalClaimsPaid += amount;
        usdc.safeTransfer(claimant, amount);
        emit ClaimPaid(poolId, amount);
    }

    /// @notice Record premium payment to pool
    function recordPremium(uint256 poolId, uint256 amount) external onlyOwner {
        pools[poolId].totalPremiumsEarned += amount;
    }

    // View functions

    function getPool(uint256 poolId) external view returns (
        address underwriter, uint256 totalStaked, uint256 availableCapacity,
        uint256 premiumsEarned, uint256 claimsPaid, bool active
    ) {
        Pool storage pool = pools[poolId];
        return (pool.underwriter, pool.totalStaked, pool.availableCapacity,
                pool.totalPremiumsEarned, pool.totalClaimsPaid, pool.active);
    }

    function getPoolTerms(uint256 poolId) external view returns (
        uint256 maxPayoutPerClaim, uint256 premiumRateBps,
        uint256 minCoveragePeriod, uint256 maxCoveragePeriod
    ) {
        CoverageTerms storage t = pools[poolId].terms;
        return (t.maxPayoutPerClaim, t.premiumRateBps, t.minCoveragePeriod, t.maxCoveragePeriod);
    }

    function getUnderwriterPools(address underwriter) external view returns (uint256[] memory) {
        return underwriterPools[underwriter];
    }
}
