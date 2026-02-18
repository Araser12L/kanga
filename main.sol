// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Kanga
 * @notice On-chain copycat trading: mirror designated leaders' trades with configurable size and slippage. Replica positions and trail execution.
 * @dev Deploy-time config immutable; operator can update router within cap. ReentrancyGuard and explicit validation throughout.
 */

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";

interface IERC20Min {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IRouterMin {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);
}

contract Kanga is ReentrancyGuard, Ownable {

    event MirrorEnrolled(
        address indexed follower,
        address indexed leader,
        uint256 maxAllocWei,
        uint256 trailSlippageBps,
        uint256 sessionId,
        uint256 atBlock
    );
    event MirrorUnenrolled(address indexed follower, address indexed leader, uint256 sessionId, uint256 atBlock);
    event TrailExecuted(
        address indexed leader,
        address indexed follower,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 trailId,
        uint256 atBlock
    );
    event ReplicaOpened(
        address indexed follower,
        address indexed leader,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 replicaId,
        uint256 atBlock
    );
    event ReplicaClosed(
        address indexed follower,
        uint256 indexed replicaId,
        uint256 amountOut,
        uint256 feeWei,
        uint256 atBlock
    );
    event LeaderDesignated(address indexed leader, uint256 maxFollowersCap, uint256 leaderId, uint256 atBlock);
    event LeaderRevoked(address indexed leader, uint256 leaderId, uint256 atBlock);
    event RooFeeWithdrawn(address indexed to, uint256 amountWei, uint256 atBlock);
    event RooRouterUpdated(address indexed previousRouter, address indexed newRouter, uint256 updateNumber);
    event RooOperatorSet(address indexed previousOperator, address indexed newOperator);
    event RooBotHaltToggled(bool halted);
    event TrailBatchExecuted(
        address indexed leader,
        uint256 trailCount,
        uint256 totalVolumeIn,
        uint256 fromTrailId,
        uint256 atBlock
    );

    error Roo_ZeroAmount();
    error Roo_ZeroAddress();
    error Roo_PathLength();
    error Roo_SlippageExceeded();
    error Roo_TransferInFailed();
    error Roo_TransferOutFailed();
    error Roo_ApproveFailed();
    error Roo_RouterCallFailed();
    error Roo_BotHalted();
    error Roo_NotOperator();
    error Roo_LeaderNotFound();
    error Roo_LeaderCapReached();
    error Roo_MirrorSessionNotFound();
    error Roo_ReplicaNotFound();
    error Roo_ReplicaAlreadyClosed();
    error Roo_RouterUpdatesExhausted();
    error Roo_MaxLeadersReached();
    error Roo_AlreadyLeader();
    error Roo_NotEnrolled();
    error Roo_AllocExceeded();
    error Roo_CooldownActive();
    error Roo_BatchLengthMismatch();

    uint256 public constant MIRROR_FEE_BPS = 15;
    uint256 public constant BPS_BASE = 10000;
    uint256 public constant MIN_PATH_LEN = 2;
    uint256 public constant MAX_PATH_LEN = 6;
    uint256 public constant MAX_ROUTER_UPDATES = 7;
    uint256 public constant MAX_LEADERS = 50;
    uint256 public constant MAX_FOLLOWERS_PER_LEADER = 200;
    uint256 public constant TRAIL_COOLDOWN_BLOCKS = 3;
    uint256 public constant REPLICA_MAX_OPEN = 32;
    uint256 public constant ROO_DOMAIN_SEED = 0x8F7E6D5C4B3A2918F6E5D4C3B2A1908E7D6C5B4A3928;

    address public immutable feeVault;
    address public immutable weth;
    uint256 public immutable genesisBlock;
    bytes32 public immutable chainSalt;

    address public router;
    address public operator;
    uint256 public routerUpdateCount;
    uint256 public trailCounter;
    uint256 public replicaCounter;
    uint256 public leaderCounter;
    uint256 public sessionCounter;
    bool public botHalted;

    struct LeaderProfile {
        address leader;
        uint256 maxFollowersCap;
        uint256 followerCount;
        uint256 totalVolumeIn;
        bool active;
        uint256 registeredAtBlock;
    }

    struct MirrorSession {
        address follower;
        address leader;
        uint256 maxAllocWei;
        uint256 usedAllocWei;
        uint256 trailSlippageBps;
        uint256 openedAtBlock;
        bool active;
    }

    struct ReplicaPosition {
        address follower;
        address leader;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 openedAtBlock;
        bool closed;
        uint256 amountOutOnClose;
    }

    struct TrailRecord {
        address leader;
        address follower;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
