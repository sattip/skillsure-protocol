// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title ValidatorRegistry
/// @notice Manages validator staking and reputation scoring for SkillSure Protocol
contract ValidatorRegistry is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Validator {
        uint256 stakeAmount;
        uint256 reputation;
        uint256 registeredAt;
        bool active;
        uint256 totalVotes;
        uint256 honestVotes;
    }

    IERC20 public immutable usdc;
    mapping(address => Validator) public validators;

    uint256 public constant MIN_STAKE = 500e6; // 500 USDC
    uint256 public constant MAX_REPUTATION = 200;
    uint256 public constant INITIAL_REPUTATION = 100;
    uint256 public constant HONEST_REPUTATION_BONUS = 5;
    uint256 public constant DISHONEST_REPUTATION_PENALTY = 20;
    uint256 public constant MIN_REPUTATION_FOR_ACTIVE = 20;

    event ValidatorRegistered(address indexed validator, uint256 stakeAmount);
    event ValidatorDeregistered(address indexed validator, uint256 stakeReturned);
    event ValidatorSlashed(address indexed validator, uint256 amount);
    event ValidatorRewarded(address indexed validator, uint256 amount);
    event ReputationUpdated(address indexed validator, uint256 newReputation, bool honest);

    constructor(address _usdc) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
    }

    /// @notice Register as a validator by staking USDC
    function registerValidator(uint256 stakeAmount) external nonReentrant {
        require(!validators[msg.sender].active, "Already registered");
        require(stakeAmount >= MIN_STAKE, "Stake below minimum");

        usdc.safeTransferFrom(msg.sender, address(this), stakeAmount);

        validators[msg.sender] = Validator({
            stakeAmount: stakeAmount,
            reputation: INITIAL_REPUTATION,
            registeredAt: block.timestamp,
            active: true,
            totalVotes: 0,
            honestVotes: 0
        });

        emit ValidatorRegistered(msg.sender, stakeAmount);
    }

    /// @notice Deregister and return staked USDC
    function deregisterValidator() external nonReentrant {
        Validator storage v = validators[msg.sender];
        require(v.active, "Not active validator");

        uint256 stakeToReturn = v.stakeAmount;
        v.active = false;
        v.stakeAmount = 0;

        usdc.safeTransfer(msg.sender, stakeToReturn);

        emit ValidatorDeregistered(msg.sender, stakeToReturn);
    }

    /// @notice Slash a validator's stake and reputation
    function slash(address validator, uint256 amount) external onlyOwner {
        Validator storage v = validators[validator];
        require(v.active, "Not active validator");
        require(amount <= v.stakeAmount, "Slash exceeds stake");

        v.stakeAmount -= amount;

        if (v.reputation > DISHONEST_REPUTATION_PENALTY) {
            v.reputation -= DISHONEST_REPUTATION_PENALTY;
        } else {
            v.reputation = 0;
        }

        usdc.safeTransfer(owner(), amount);

        emit ValidatorSlashed(validator, amount);
    }

    /// @notice Reward a validator with additional USDC and reputation boost
    function reward(address validator, uint256 amount) external onlyOwner nonReentrant {
        Validator storage v = validators[validator];
        require(v.active, "Not active validator");

        if (amount > 0) {
            usdc.safeTransferFrom(msg.sender, address(this), amount);
            v.stakeAmount += amount;
        }

        if (v.reputation + HONEST_REPUTATION_BONUS <= MAX_REPUTATION) {
            v.reputation += HONEST_REPUTATION_BONUS;
        } else {
            v.reputation = MAX_REPUTATION;
        }

        emit ValidatorRewarded(validator, amount);
    }

    /// @notice Update a validator's reputation based on vote honesty
    function updateReputation(address validator, bool honest) external onlyOwner {
        Validator storage v = validators[validator];
        require(v.active, "Not active validator");

        v.totalVotes++;

        if (honest) {
            v.honestVotes++;
            if (v.reputation + HONEST_REPUTATION_BONUS <= MAX_REPUTATION) {
                v.reputation += HONEST_REPUTATION_BONUS;
            } else {
                v.reputation = MAX_REPUTATION;
            }
        } else {
            if (v.reputation > DISHONEST_REPUTATION_PENALTY) {
                v.reputation -= DISHONEST_REPUTATION_PENALTY;
            } else {
                v.reputation = 0;
            }
        }

        emit ReputationUpdated(validator, v.reputation, honest);
    }

    // View functions

    /// @notice Check if an address qualifies as an active validator
    function isValidator(address account) external view returns (bool) {
        Validator storage v = validators[account];
        return v.active && v.stakeAmount >= MIN_STAKE && v.reputation >= MIN_REPUTATION_FOR_ACTIVE;
    }

    /// @notice Get a validator's current reputation score
    function getReputation(address account) external view returns (uint256) {
        return validators[account].reputation;
    }

    /// @notice Get a validator's current stake amount
    function getStake(address account) external view returns (uint256) {
        return validators[account].stakeAmount;
    }

    /// @notice Get full validator info
    function getValidatorInfo(address account) external view returns (
        uint256 stakeAmount,
        uint256 reputation,
        uint256 registeredAt,
        bool active,
        uint256 totalVotes,
        uint256 honestVotes
    ) {
        Validator storage v = validators[account];
        return (v.stakeAmount, v.reputation, v.registeredAt, v.active, v.totalVotes, v.honestVotes);
    }
}
