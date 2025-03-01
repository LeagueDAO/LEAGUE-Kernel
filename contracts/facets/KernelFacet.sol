// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.7.6;
pragma experimental ABIEncoderV2;

import "../interfaces/IKernel.sol";
import "../libraries/LibKernelStorage.sol";
import "../libraries/LibOwnership.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract KernelFacet {
    using SafeMath for uint256;

    uint256 constant public MAX_LOCK = 365 days;
    uint256 constant BASE_MULTIPLIER = 1e18;

    event Deposit(address indexed user, uint256 amount, uint256 newBalance);
    event Withdraw(address indexed user, uint256 amountWithdrew, uint256 amountLeft);
    event Lock(address indexed user, uint256 timestamp);
    event Delegate(address indexed from, address indexed to);
    event DelegatedPowerIncreased(address indexed from, address indexed to, uint256 amount, uint256 to_newDelegatedPower);
    event DelegatedPowerDecreased(address indexed from, address indexed to, uint256 amount, uint256 to_newDelegatedPower);

    function initKernel(address _leag, address _rewards) public {
        require(_leag != address(0), "LEAG address must not be 0x0");

        LibKernelStorage.Storage storage ds = LibKernelStorage.kernelStorage();

        require(!ds.initialized, "Kernel: already initialized");
        LibOwnership.enforceIsContractOwner();

        ds.initialized = true;

        ds.leag = IERC20(_leag);
        ds.rewards = IRewards(_rewards);
    }

    // deposit allows a user to add more leag to his staked balance
    function deposit(uint256 amount) public {
        require(amount > 0, "Amount must be greater than 0");

       LibKernelStorage.Storage storage ds = LibKernelStorage.kernelStorage();
        uint256 allowance = ds.leag.allowance(msg.sender, address(this));
        require(allowance >= amount, "Token allowance too small");

        // this must be called before the user's balance is updated so the rewards contract can calculate
        // the amount owed correctly
        if (address(ds.rewards) != address(0)) {
            ds.rewards.registerUserAction(msg.sender);
        }

        uint256 newBalance = balanceOf(msg.sender).add(amount);
        _updateUserBalance(ds.userStakeHistory[msg.sender], newBalance);
        _updateLockedLeag(leagStakedAtTs(block.timestamp).add(amount));

        address delegatedTo = userDelegatedTo(msg.sender);
        if (delegatedTo != address(0)) {
            uint256 newDelegatedPower = delegatedPower(delegatedTo).add(amount);
            _updateDelegatedPower(ds.delegatedPowerHistory[delegatedTo], newDelegatedPower);

            emit DelegatedPowerIncreased(msg.sender, delegatedTo, amount, newDelegatedPower);
        }
        ds.leag.transferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, amount, newBalance);
    }

    // withdraw allows a user to withdraw funds if the balance is not locked
    function withdraw(uint256 amount) public {
        require(amount > 0, "Amount must be greater than 0");
        require(userLockedUntil(msg.sender) <= block.timestamp, "User balance is locked");

        uint256 balance = balanceOf(msg.sender);
        require(balance >= amount, "Insufficient balance");

        LibKernelStorage.Storage storage ds = LibKernelStorage.kernelStorage();

        // this must be called before the user's balance is updated so the rewards contract can calculate
        // the amount owed correctly
        if (address(ds.rewards) != address(0)) {
            ds.rewards.registerUserAction(msg.sender);
        }

        _updateUserBalance(ds.userStakeHistory[msg.sender], balance.sub(amount));
        _updateLockedLeag(leagStakedAtTs(block.timestamp).sub(amount));

        address delegatedTo = userDelegatedTo(msg.sender);
        if (delegatedTo != address(0)) {
            uint256 newDelegatedPower = delegatedPower(delegatedTo).sub(amount);
            _updateDelegatedPower(ds.delegatedPowerHistory[delegatedTo], newDelegatedPower);

            emit DelegatedPowerDecreased(msg.sender, delegatedTo, amount, newDelegatedPower);
        }

        ds.leag.transfer(msg.sender, amount);

        emit Withdraw(msg.sender, amount, balance.sub(amount));
    }

    // lock a user's currently staked balance until timestamp & add the bonus to his voting power
    function lock(uint256 timestamp) public {
        require(timestamp > block.timestamp, "Timestamp must be in the future");
        require(timestamp <= block.timestamp + MAX_LOCK, "Timestamp too big");
        require(balanceOf(msg.sender) > 0, "Sender has no balance");

        LibKernelStorage.Storage storage ds = LibKernelStorage.kernelStorage();
        LibKernelStorage.Stake[] storage checkpoints = ds.userStakeHistory[msg.sender];
        LibKernelStorage.Stake storage currentStake = checkpoints[checkpoints.length - 1];

        require(timestamp > currentStake.expiryTimestamp, "New timestamp lower than current lock timestamp");

        _updateUserLock(checkpoints, timestamp);

        emit Lock(msg.sender, timestamp);
    }

    function depositAndLock(uint256 amount, uint256 timestamp) public {
        deposit(amount);
        lock(timestamp);
    }

    // delegate allows a user to delegate his voting power to another user
    function delegate(address to) public {
        require(msg.sender != to, "Can't delegate to self");

        uint256 senderBalance = balanceOf(msg.sender);
        require(senderBalance > 0, "No balance to delegate");

        LibKernelStorage.Storage storage ds = LibKernelStorage.kernelStorage();

        emit Delegate(msg.sender, to);

        address delegatedTo = userDelegatedTo(msg.sender);
        if (delegatedTo != address(0)) {
            uint256 newDelegatedPower = delegatedPower(delegatedTo).sub(senderBalance);
            _updateDelegatedPower(ds.delegatedPowerHistory[delegatedTo], newDelegatedPower);

            emit DelegatedPowerDecreased(msg.sender, delegatedTo, senderBalance, newDelegatedPower);
        }

        if (to != address(0)) {
            uint256 newDelegatedPower = delegatedPower(to).add(senderBalance);
            _updateDelegatedPower(ds.delegatedPowerHistory[to], newDelegatedPower);

            emit DelegatedPowerIncreased(msg.sender, to, senderBalance, newDelegatedPower);
        }

        _updateUserDelegatedTo(ds.userStakeHistory[msg.sender], to);
    }

    // stopDelegate allows a user to take back the delegated voting power
    function stopDelegate() public {
        return delegate(address(0));
    }

    // balanceOf returns the current LEAG balance of a user (bonus not included)
    function balanceOf(address user) public view returns (uint256) {
        return balanceAtTs(user, block.timestamp);
    }

    // balanceAtTs returns the amount of LEAG that the user currently staked (bonus NOT included)
    function balanceAtTs(address user, uint256 timestamp) public view returns (uint256) {
        LibKernelStorage.Stake memory stake = stakeAtTs(user, timestamp);

        return stake.amount;
    }

    // stakeAtTs returns the Stake object of the user that was valid at `timestamp`
    function stakeAtTs(address user, uint256 timestamp) public view returns (LibKernelStorage.Stake memory) {
        LibKernelStorage.Storage storage ds = LibKernelStorage.kernelStorage();
        LibKernelStorage.Stake[] storage stakeHistory = ds.userStakeHistory[user];

        if (stakeHistory.length == 0 || timestamp < stakeHistory[0].timestamp) {
            return LibKernelStorage.Stake(block.timestamp, 0, block.timestamp, address(0));
        }

        uint256 min = 0;
        uint256 max = stakeHistory.length - 1;

        if (timestamp >= stakeHistory[max].timestamp) {
            return stakeHistory[max];
        }

        // binary search of the value in the array
        while (max > min) {
            uint256 mid = (max + min + 1) / 2;
            if (stakeHistory[mid].timestamp <= timestamp) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }

        return stakeHistory[min];
    }

    // votingPower returns the voting power (bonus included) + delegated voting power for a user at the current block
    function votingPower(address user) public view returns (uint256) {
        return votingPowerAtTs(user, block.timestamp);
    }

    // votingPowerAtTs returns the voting power (bonus included) + delegated voting power for a user at a point in time
    function votingPowerAtTs(address user, uint256 timestamp) public view returns (uint256) {
        LibKernelStorage.Stake memory stake = stakeAtTs(user, timestamp);

        uint256 ownVotingPower;

        // if the user delegated his voting power to another user, then he doesn't have any voting power left
        if (stake.delegatedTo != address(0)) {
            ownVotingPower = 0;
        } else {
            uint256 balance = stake.amount;
            uint256 multiplier = _stakeMultiplier(stake, timestamp);
            ownVotingPower = balance.mul(multiplier).div(BASE_MULTIPLIER);
        }

        uint256 delegatedVotingPower = delegatedPowerAtTs(user, timestamp);

        return ownVotingPower.add(delegatedVotingPower);
    }

    // leagStaked returns the total raw amount of LEAG staked at the current block
    function leagStaked() public view returns (uint256) {
        return leagStakedAtTs(block.timestamp);
    }

    // leagStakedAtTs returns the total raw amount of LEAG users have deposited into the contract
    // it does not include any bonus
    function leagStakedAtTs(uint256 timestamp) public view returns (uint256) {
        return _checkpointsBinarySearch(LibKernelStorage.kernelStorage().leagStakedHistory, timestamp);
    }

    // delegatedPower returns the total voting power that a user received from other users
    function delegatedPower(address user) public view returns (uint256) {
        return delegatedPowerAtTs(user, block.timestamp);
    }

    // delegatedPowerAtTs returns the total voting power that a user received from other users at a point in time
    function delegatedPowerAtTs(address user, uint256 timestamp) public view returns (uint256) {
        return _checkpointsBinarySearch(LibKernelStorage.kernelStorage().delegatedPowerHistory[user], timestamp);
    }

    // same as multiplierAtTs but for the current block timestamp
    function multiplierOf(address user) public view returns (uint256) {
        return multiplierAtTs(user, block.timestamp);
    }

    // multiplierAtTs calculates the multiplier at a given timestamp based on the user's stake a the given timestamp
    // it includes the decay mechanism
    function multiplierAtTs(address user, uint256 timestamp) public view returns (uint256) {
        LibKernelStorage.Stake memory stake = stakeAtTs(user, timestamp);

        return _stakeMultiplier(stake, timestamp);
    }

    // userLockedUntil returns the timestamp until the user's balance is locked
    function userLockedUntil(address user) public view returns (uint256) {
        LibKernelStorage.Stake memory c = stakeAtTs(user, block.timestamp);

        return c.expiryTimestamp;
    }

    // userDelegatedTo returns the address to which a user delegated their voting power; address(0) if not delegated
    function userDelegatedTo(address user) public view returns (address) {
        LibKernelStorage.Stake memory c = stakeAtTs(user, block.timestamp);

        return c.delegatedTo;
    }

    // _checkpointsBinarySearch executes a binary search on a list of checkpoints that's sorted chronologically
    // looking for the closest checkpoint that matches the specified timestamp
    function _checkpointsBinarySearch(LibKernelStorage.Checkpoint[] storage checkpoints, uint256 timestamp) internal view returns (uint256) {
        if (checkpoints.length == 0 || timestamp < checkpoints[0].timestamp) {
            return 0;
        }

        uint256 min = 0;
        uint256 max = checkpoints.length - 1;

        if (timestamp >= checkpoints[max].timestamp) {
            return checkpoints[max].amount;
        }

        // binary search of the value in the array
        while (max > min) {
            uint256 mid = (max + min + 1) / 2;
            if (checkpoints[mid].timestamp <= timestamp) {
                min = mid;
            } else {
                max = mid - 1;
            }
        }

        return checkpoints[min].amount;
    }

    // _stakeMultiplier calculates the multiplier for the given stake at the given timestamp
    function _stakeMultiplier(LibKernelStorage.Stake memory stake, uint256 timestamp) internal view returns (uint256) {
        if (timestamp >= stake.expiryTimestamp) {
            return BASE_MULTIPLIER;
        }

        uint256 diff = stake.expiryTimestamp - timestamp;
        if (diff >= MAX_LOCK) {
            return BASE_MULTIPLIER.mul(2);
        }

        return BASE_MULTIPLIER.add(diff.mul(BASE_MULTIPLIER).div(MAX_LOCK));
    }

    // _updateUserBalance manages an array of checkpoints
    // if there's already a checkpoint for the same timestamp, the amount is updated
    // otherwise, a new checkpoint is inserted
    function _updateUserBalance(LibKernelStorage.Stake[] storage checkpoints, uint256 amount) internal {
        if (checkpoints.length == 0) {
            checkpoints.push(LibKernelStorage.Stake(block.timestamp, amount, block.timestamp, address(0)));
        } else {
            LibKernelStorage.Stake storage old = checkpoints[checkpoints.length - 1];

            if (old.timestamp == block.timestamp) {
                old.amount = amount;
            } else {
                checkpoints.push(LibKernelStorage.Stake(block.timestamp, amount, old.expiryTimestamp, old.delegatedTo));
            }
        }
    }

    // _updateUserLock updates the expiry timestamp on the user's stake
    // it assumes that if the user already has a balance, which is checked for in the lock function
    // then there must be at least 1 checkpoint
    function _updateUserLock(LibKernelStorage.Stake[] storage checkpoints, uint256 expiryTimestamp) internal {
        LibKernelStorage.Stake storage old = checkpoints[checkpoints.length - 1];

        if (old.timestamp < block.timestamp) {
            checkpoints.push(LibKernelStorage.Stake(block.timestamp, old.amount, expiryTimestamp, old.delegatedTo));
        } else {
            old.expiryTimestamp = expiryTimestamp;
        }
    }

    // _updateUserDelegatedTo updates the delegateTo property on the user's stake
    // it assumes that if the user already has a balance, which is checked for in the delegate function
    // then there must be at least 1 checkpoint
    function _updateUserDelegatedTo(LibKernelStorage.Stake[] storage checkpoints, address to) internal {
        LibKernelStorage.Stake storage old = checkpoints[checkpoints.length - 1];

        if (old.timestamp < block.timestamp) {
            checkpoints.push(LibKernelStorage.Stake(block.timestamp, old.amount, old.expiryTimestamp, to));
        } else {
            old.delegatedTo = to;
        }
    }

    // _updateDelegatedPower updates the power delegated TO the user in the checkpoints history
    function _updateDelegatedPower(LibKernelStorage.Checkpoint[] storage checkpoints, uint256 amount) internal {
        if (checkpoints.length == 0 || checkpoints[checkpoints.length - 1].timestamp < block.timestamp) {
            checkpoints.push(LibKernelStorage.Checkpoint(block.timestamp, amount));
        } else {
            LibKernelStorage.Checkpoint storage old = checkpoints[checkpoints.length - 1];
            old.amount = amount;
        }
    }

    // _updateLockedLeag stores the new `amount` into the LEAG locked history
    function _updateLockedLeag(uint256 amount) internal {
        LibKernelStorage.Storage storage ds = LibKernelStorage.kernelStorage();

        if (ds.leagStakedHistory.length == 0 || ds.leagStakedHistory[ds.leagStakedHistory.length - 1].timestamp < block.timestamp) {
            ds.leagStakedHistory.push(LibKernelStorage.Checkpoint(block.timestamp, amount));
        } else {
            LibKernelStorage.Checkpoint storage old = ds.leagStakedHistory[ds.leagStakedHistory.length - 1];
            old.amount = amount;
        }
    }
}
