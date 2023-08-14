// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.19;

import {BaseHook} from "@uniswap/v4-periphery/contracts/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {PoolKey} from "@uniswap/v4-core/contracts/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/contracts/types/PoolId.sol";
import {Position} from "@uniswap/v4-core/contracts/libraries/Position.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";

/// @title  VotingEscrowHook
/// @author Curve Finance (MIT) - original concept and implementation in Vyper
///           (see https://github.com/curvefi/curve-dao-contracts/blob/master/contracts/VotingEscrow.vy)
///         mStable (AGPL) - forking Curve's Vyper contract and porting to Solidity
///           (see https://github.com/mstable/mStable-contracts/blob/master/contracts/governance/IncentivisedVotingLockup.sol)
///         FIAT DAO (AGPL) - https://github.com/code-423n4/2022-08-fiatdao/blob/main/contracts/VotingEscrow.sol
///         VotingEscrowHook (AGPL) - This version, forked and applied to Uniswap v4 hook by https://github.com/kadenzipfel
/// @notice Curve VotingEscrow mechanics applied to Uniswap v4 hook
contract VotingEscrowHook is BaseHook, ReentrancyGuard {
    // Shared Events
    event Deposit(
        address indexed provider,
        uint256 value,
        uint256 locktime,
        LockAction indexed action,
        uint256 ts
    );
    event Withdraw(
        address indexed provider,
        uint256 value,
        LockAction indexed action,
        uint256 ts
    );

    // Pool ID
    PoolId poolId;

    // Shared global state
    ERC20 public token;
    uint256 public constant WEEK = 7 days;
    uint256 public constant MAXTIME = 365 days;
    uint256 public constant MULTIPLIER = 10**18;

    // Lock state
    uint256 public globalEpoch;
    Point[1000000000000000000] public pointHistory; // 1e9 * userPointHistory-length, so sufficient for 1e9 users
    mapping(address => Point[1000000000]) public userPointHistory;
    mapping(address => uint256) public userPointEpoch;
    mapping(uint256 => int128) public slopeChanges;
    mapping(address => LockedBalance) public locked;
    mapping(address => LockTicks) public lockTicks;

    // Voting token
    string public name;
    string public symbol;
    uint256 public decimals = 18;

    // Structs
    struct Point {
        int128 bias;
        int128 slope;
        uint256 ts;
        uint256 blk;
    }
    struct LockedBalance {
        int128 amount;
        uint256 end;
    }
    struct LockTicks {
        int24 lowerTick;
        int24 upperTick;
    }

    // Miscellaneous
    enum LockAction {
        CREATE,
        INCREASE_TIME
    }

    constructor(
        PoolId _poolId,
        address _token,
        string memory _name,
        string memory _symbol
    ) BaseHook(IPoolManager(msg.sender)) {
        poolId = _poolId;

        token = ERC20(_token);
        pointHistory[0] = Point({
            bias: int128(0),
            slope: int128(0),
            ts: block.timestamp,
            blk: block.number
        });

        decimals = ERC20(_token).decimals();
        require(decimals <= 18, "Exceeds max decimals");

        name = _name;
        symbol = _symbol;
    }

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: false,
            afterInitialize: false,
            beforeModifyPosition: true,
            afterModifyPosition: true,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false
        });
    }

    function beforeModifyPosition(address sender, PoolKey calldata, IPoolManager.ModifyPositionParams calldata modifyPositionParams)
        external
        view
        override
        poolManagerOnly
        returns (bytes4)
    {
        LockTicks memory lockTicks_ = lockTicks[sender];
        if (lockTicks_.lowerTick != modifyPositionParams.tickLower || lockTicks_.upperTick != modifyPositionParams.tickUpper) {
            // Not modifying locked position, continue execution
            return VotingEscrowHook.beforeModifyPosition.selector;    
        }

        LockedBalance memory locked_ = locked[sender];
        // Can only increase position liquidity while locked
        require(modifyPositionParams.liquidityDelta > 0 || locked_.end <= block.timestamp, "Can't withdraw before lock end");
        return VotingEscrowHook.beforeModifyPosition.selector;
    }

    function afterModifyPosition(address sender, PoolKey calldata, IPoolManager.ModifyPositionParams calldata modifyPositionParams, BalanceDelta)
        external
        view
        override
        poolManagerOnly
        returns (bytes4)
    {
        LockTicks memory lockTicks_ = lockTicks[sender];
        if (lockTicks_.lowerTick != modifyPositionParams.tickLower || lockTicks_.upperTick != modifyPositionParams.tickUpper) {
            // Not modifying locked position, continue execution
            return VotingEscrowHook.beforeModifyPosition.selector;    
        }

        Position.Info memory position = poolManager.getPosition(poolId, msg.sender, modifyPositionParams.tickLower, modifyPositionParams.tickUpper);
        LockedBalance memory locked_ = locked[msg.sender];
        locked_.amount = int128(position.liquidity);

        return VotingEscrowHook.beforeModifyPosition.selector;
    }

    /// ~~~~~~~~~~~~~~~~~~~~~~~~~~~ ///
    ///       LOCK MANAGEMENT       ///
    /// ~~~~~~~~~~~~~~~~~~~~~~~~~~~ ///

    /// @notice Returns a user's lock expiration
    /// @param _addr The address of the user
    /// @return Expiration of the user's lock
    function lockEnd(address _addr) external view returns (uint256) {
        return locked[_addr].end;
    }

    /// @notice Returns the last available user point for a user
    /// @param _addr User address
    /// @return bias i.e. y
    /// @return slope i.e. linear gradient
    /// @return ts i.e. time point was logged
    function getLastUserPoint(address _addr)
        external
        view
        returns (
            int128 bias,
            int128 slope,
            uint256 ts
        )
    {
        uint256 uepoch = userPointEpoch[_addr];
        if (uepoch == 0) {
            return (0, 0, 0);
        }
        Point memory point = userPointHistory[_addr][uepoch];
        return (point.bias, point.slope, point.ts);
    }

    /// @notice Records a checkpoint of both individual and global slope
    /// @param _addr User address, or address(0) for only global
    /// @param _oldLocked Old amount that user had locked, or null for global
    /// @param _newLocked new amount that user has locked, or null for global
    function _checkpoint(
        address _addr,
        LockedBalance memory _oldLocked,
        LockedBalance memory _newLocked
    ) internal {
        Point memory userOldPoint;
        Point memory userNewPoint;
        int128 oldSlopeDelta = 0;
        int128 newSlopeDelta = 0;
        uint256 epoch = globalEpoch;

        if (_addr != address(0)) {
            // Calculate slopes and biases
            // Kept at zero when they have to
            if (_oldLocked.end > block.timestamp) {
                userOldPoint.slope =
                    _oldLocked.amount /
                    int128(int256(MAXTIME));
                userOldPoint.bias =
                    userOldPoint.slope *
                    int128(int256(_oldLocked.end - block.timestamp));
            }
            if (_newLocked.end > block.timestamp) {
                userNewPoint.slope =
                    _newLocked.amount /
                    int128(int256(MAXTIME));
                userNewPoint.bias =
                    userNewPoint.slope *
                    int128(int256(_newLocked.end - block.timestamp));
            }

            // Moved from bottom final if statement to resolve stack too deep err
            // start {
            // Now handle user history
            uint256 uEpoch = userPointEpoch[_addr];
            if (uEpoch == 0) {
                userPointHistory[_addr][uEpoch + 1] = userOldPoint;
            }

            userPointEpoch[_addr] = uEpoch + 1;
            userNewPoint.ts = block.timestamp;
            userNewPoint.blk = block.number;
            userPointHistory[_addr][uEpoch + 1] = userNewPoint;

            // } end

            // Read values of scheduled changes in the slope
            // oldLocked.end can be in the past and in the future
            // newLocked.end can ONLY by in the FUTURE unless everything expired: than zeros
            oldSlopeDelta = slopeChanges[_oldLocked.end];
            if (_newLocked.end != 0) {
                if (_newLocked.end == _oldLocked.end) {
                    newSlopeDelta = oldSlopeDelta;
                } else {
                    newSlopeDelta = slopeChanges[_newLocked.end];
                }
            }
        }

        Point memory lastPoint =
            Point({
                bias: 0,
                slope: 0,
                ts: block.timestamp,
                blk: block.number
            });
        if (epoch > 0) {
            lastPoint = pointHistory[epoch];
        }
        uint256 lastCheckpoint = lastPoint.ts;

        // initialLastPoint is used for extrapolation to calculate block number
        // (approximately, for *At methods) and save them
        // as we cannot figure that out exactly from inside the contract
        Point memory initialLastPoint =
            Point({ bias: 0, slope: 0, ts: lastPoint.ts, blk: lastPoint.blk });
        uint256 blockSlope = 0; // dblock/dt
        if (block.timestamp > lastPoint.ts) {
            blockSlope =
                (MULTIPLIER * (block.number - lastPoint.blk)) /
                (block.timestamp - lastPoint.ts);
        }
        // If last point is already recorded in this block, slope=0
        // But that's ok b/c we know the block in such case

        // Go over weeks to fill history and calculate what the current point is
        uint256 iterativeTime = _floorToWeek(lastCheckpoint);
        for (uint256 i = 0; i < 255; i++) {
            // Hopefully it won't happen that this won't get used in 5 years!
            // If it does, users will be able to withdraw but vote weight will be broken
            iterativeTime = iterativeTime + WEEK;
            int128 dSlope = 0;
            if (iterativeTime > block.timestamp) {
                iterativeTime = block.timestamp;
            } else {
                dSlope = slopeChanges[iterativeTime];
            }
            int128 biasDelta =
                lastPoint.slope *
                    int128(int256((iterativeTime - lastCheckpoint)));
            lastPoint.bias = lastPoint.bias - biasDelta;
            lastPoint.slope = lastPoint.slope + dSlope;
            // This can happen
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }
            // This cannot happen - just in case
            if (lastPoint.slope < 0) {
                lastPoint.slope = 0;
            }
            lastCheckpoint = iterativeTime;
            lastPoint.ts = iterativeTime;
            lastPoint.blk =
                initialLastPoint.blk +
                (blockSlope * (iterativeTime - initialLastPoint.ts)) /
                MULTIPLIER;

            // when epoch is incremented, we either push here or after slopes updated below
            epoch = epoch + 1;
            if (iterativeTime == block.timestamp) {
                lastPoint.blk = block.number;
                break;
            } else {
                pointHistory[epoch] = lastPoint;
            }
        }

        globalEpoch = epoch;
        // Now pointHistory is filled until t=now

        if (_addr != address(0)) {
            // If last point was in this block, the slope change has been applied already
            // But in such case we have 0 slope(s)
            lastPoint.slope =
                lastPoint.slope +
                userNewPoint.slope -
                userOldPoint.slope;
            lastPoint.bias =
                lastPoint.bias +
                userNewPoint.bias -
                userOldPoint.bias;
            if (lastPoint.slope < 0) {
                lastPoint.slope = 0;
            }
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }
        }

        // Record the changed point into history
        pointHistory[epoch] = lastPoint;

        if (_addr != address(0)) {
            // Schedule the slope changes (slope is going down)
            // We subtract new_user_slope from [new_locked.end]
            // and add old_user_slope to [old_locked.end]
            if (_oldLocked.end > block.timestamp) {
                // oldSlopeDelta was <something> - userOldPoint.slope, so we cancel that
                oldSlopeDelta = oldSlopeDelta + userOldPoint.slope;
                if (_newLocked.end == _oldLocked.end) {
                    oldSlopeDelta = oldSlopeDelta - userNewPoint.slope; // It was a new deposit, not extension
                }
                slopeChanges[_oldLocked.end] = oldSlopeDelta;
            }
            if (_newLocked.end > block.timestamp) {
                if (_newLocked.end > _oldLocked.end) {
                    newSlopeDelta = newSlopeDelta - userNewPoint.slope; // old slope disappeared at this point
                    slopeChanges[_newLocked.end] = newSlopeDelta;
                }
                // else: we recorded it already in oldSlopeDelta
            }
        }
    }

    /// @notice Public function to trigger global checkpoint
    function checkpoint() external {
        LockedBalance memory empty;
        _checkpoint(address(0), empty, empty);
    }

    /// @notice Creates a new lock
    /// @param _unlockTime Time at which the lock expires
    /// @param _tickLower Lower tick for liquidity position
    /// @param _tickUpper Upper tick for liquidity position
    function createLock(uint256 _unlockTime, int24 _tickLower, int24 _tickUpper)
        external
        nonReentrant
    {
        uint256 unlock_time = _floorToWeek(_unlockTime); // Locktime is rounded down to weeks
        LockedBalance memory locked_ = locked[msg.sender];
        Position.Info memory position = poolManager.getPosition(poolId, msg.sender, _tickLower, _tickUpper);
        uint256 value = uint256(position.liquidity);

        // Validate inputs
        require(value > 0, "No liquidity position");
        require(locked_.amount == 0, "Lock exists");
        require(unlock_time >= locked_.end, "Only increase lock end");
        require(unlock_time > block.timestamp, "Only future lock end");
        require(unlock_time <= block.timestamp + MAXTIME, "Exceeds maxtime");
        // Update lock and voting power (checkpoint)
        locked_.amount = int128(uint128(value));
        locked_.end = unlock_time;
        locked[msg.sender] = locked_;
        lockTicks[msg.sender] = LockTicks({
            lowerTick: _tickLower,
            upperTick: _tickUpper
        });
        _checkpoint(msg.sender, LockedBalance(0, 0), locked_);
        // Deposit locked tokens
        emit Deposit(
            msg.sender,
            value,
            unlock_time,
            LockAction.CREATE,
            block.timestamp
        );
    }

    /// @notice Extends the expiration of an existing lock
    /// @param _unlockTime New lock expiration time
    /// @dev Does not update the amount of tokens locked.
    /// @dev Does increase the user's voting power.
    function increaseUnlockTime(uint256 _unlockTime)
        external
        nonReentrant
    {
        LockedBalance memory locked_ = locked[msg.sender];
        uint256 unlock_time = _floorToWeek(_unlockTime); // Locktime is rounded down to weeks
        // Validate inputs
        require(locked_.amount > 0, "No lock");
        require(unlock_time > locked_.end, "Only increase lock end");
        require(unlock_time <= block.timestamp + MAXTIME, "Exceeds maxtime");
        // Update lock
        uint256 oldUnlockTime = locked_.end;
        locked_.end = unlock_time;
        locked[msg.sender] = locked_;
        require(oldUnlockTime > block.timestamp, "Lock expired");
        LockedBalance memory oldLocked = _copyLock(locked_);
        oldLocked.end = unlock_time;
        _checkpoint(msg.sender, oldLocked, locked_);
        emit Deposit(
            msg.sender,
            0,
            unlock_time,
            LockAction.INCREASE_TIME,
            block.timestamp
        );
    }

    // Creates a copy of a lock
    function _copyLock(LockedBalance memory _locked)
        internal
        pure
        returns (LockedBalance memory)
    {
        return
            LockedBalance({
                amount: _locked.amount,
                end: _locked.end
            });
    }

    // @dev Floors a timestamp to the nearest weekly increment
    // @param _t Timestamp to floor
    function _floorToWeek(uint256 _t) internal pure returns (uint256) {
        return (_t / WEEK) * WEEK;
    }
}