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
        uint256 amountOut;
        uint256 atBlock;
    }

    mapping(uint256 => LeaderProfile) public leaderProfiles;
    mapping(address => uint256) public leaderIdByAddress;
    mapping(uint256 => MirrorSession) public mirrorSessions;
    mapping(uint256 => ReplicaPosition) public replicaPositions;
    mapping(uint256 => TrailRecord) public trailRecords;

    mapping(address => uint256[]) public sessionIdsByFollower;
    mapping(address => uint256[]) public sessionIdsByLeader;
    mapping(address => uint256[]) public replicaIdsByFollower;
    mapping(address => uint256[]) public trailIdsByLeader;
    mapping(address => uint256[]) public trailIdsByFollower;
    mapping(address => mapping(address => uint256)) public activeSessionId;
    mapping(address => uint256) public lastTrailBlockByLeader;
    mapping(address => uint256) public pendingWithdrawals;

    uint256[] private _leaderIds;
    uint256[] private _activeSessionIds;

    constructor() {
        feeVault = address(0x7F3a9E2c5B8d1F4a7C0e3B6d9F2c5A8e1B4d7C0);
        weth = address(0x2C5e8A1b4D7f0c3E6a9B2d5F8c1E4a7B0d3F6A9);
        router = address(0x9B2d5F8c1E4a7B0d3F6A9c2E5b8D1f4A7c0E3B6);
        operator = address(0x4D7f0C3e6A9b2D5f8C1e4A7b0D3f6A9c2E5b8D1);
        genesisBlock = block.number;
        chainSalt = keccak256(abi.encodePacked("Kanga_Roo_", block.chainid, block.timestamp, address(this)));
    }

    modifier whenNotHalted() {
        if (botHalted) revert Roo_BotHalted();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator && msg.sender != owner()) revert Roo_NotOperator();
        _;
    }

    function setBotHalted(bool halted) external onlyOwner {
        botHalted = halted;
        emit RooBotHaltToggled(halted);
    }

    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == address(0)) revert Roo_ZeroAddress();
        address prev = operator;
        operator = newOperator;
        emit RooOperatorSet(prev, newOperator);
    }

    function setRouter(address newRouter) external onlyOwner {
        if (routerUpdateCount >= MAX_ROUTER_UPDATES) revert Roo_RouterUpdatesExhausted();
        if (newRouter == address(0)) revert Roo_ZeroAddress();
        address prev = router;
        router = newRouter;
        routerUpdateCount++;
        emit RooRouterUpdated(prev, newRouter, routerUpdateCount);
    }

    function designateLeader(address leader, uint256 maxFollowersCap) external onlyOperator whenNotHalted {
        if (leader == address(0)) revert Roo_ZeroAddress();
        if (leaderIdByAddress[leader] != 0) revert Roo_AlreadyLeader();
        if (leaderCounter >= MAX_LEADERS) revert Roo_MaxLeadersReached();
        if (maxFollowersCap == 0 || maxFollowersCap > MAX_FOLLOWERS_PER_LEADER) revert Roo_ZeroAmount();

        leaderCounter++;
        leaderIdByAddress[leader] = leaderCounter;
        leaderProfiles[leaderCounter] = LeaderProfile({
            leader: leader,
            maxFollowersCap: maxFollowersCap,
            followerCount: 0,
            totalVolumeIn: 0,
            active: true,
            registeredAtBlock: block.number
        });
        _leaderIds.push(leaderCounter);
        emit LeaderDesignated(leader, maxFollowersCap, leaderCounter, block.number);
    }

    function revokeLeader(address leader) external onlyOperator {
        uint256 lid = leaderIdByAddress[leader];
        if (lid == 0) revert Roo_LeaderNotFound();
        leaderProfiles[lid].active = false;
        leaderIdByAddress[leader] = 0;
        emit LeaderRevoked(leader, lid, block.number);
    }

    function enrollMirror(
        address leader,
        uint256 maxAllocWei,
        uint256 trailSlippageBps
    ) external nonReentrant whenNotHalted returns (uint256 sessionId) {
        if (msg.sender == address(0) || leader == address(0)) revert Roo_ZeroAddress();
        if (maxAllocWei == 0) revert Roo_ZeroAmount();
        if (trailSlippageBps > BPS_BASE) revert Roo_SlippageExceeded();

        uint256 lid = leaderIdByAddress[leader];
        if (lid == 0) revert Roo_LeaderNotFound();
        LeaderProfile storage lp = leaderProfiles[lid];
        if (!lp.active) revert Roo_LeaderNotFound();
        if (lp.followerCount >= lp.maxFollowersCap) revert Roo_LeaderCapReached();
        if (activeSessionId[msg.sender][leader] != 0) revert Roo_NotEnrolled();

        sessionCounter++;
        sessionId = sessionCounter;
        mirrorSessions[sessionId] = MirrorSession({
            follower: msg.sender,
            leader: leader,
            maxAllocWei: maxAllocWei,
            usedAllocWei: 0,
            trailSlippageBps: trailSlippageBps,
            openedAtBlock: block.number,
            active: true
        });
        activeSessionId[msg.sender][leader] = sessionId;
        sessionIdsByFollower[msg.sender].push(sessionId);
        sessionIdsByLeader[leader].push(sessionId);
        lp.followerCount++;
        _activeSessionIds.push(sessionId);
        emit MirrorEnrolled(msg.sender, leader, maxAllocWei, trailSlippageBps, sessionId, block.number);
        return sessionId;
    }

    function unenrollMirror(uint256 sessionId) external nonReentrant {
        MirrorSession storage s = mirrorSessions[sessionId];
        if (s.follower != msg.sender) revert Roo_MirrorSessionNotFound();
        if (!s.active) revert Roo_MirrorSessionNotFound();

        s.active = false;
        uint256 lid = leaderIdByAddress[s.leader];
        if (lid != 0 && leaderProfiles[lid].followerCount > 0) leaderProfiles[lid].followerCount--;
        activeSessionId[msg.sender][s.leader] = 0;
        emit MirrorUnenrolled(msg.sender, s.leader, sessionId, block.number);
    }

    function executeTrail(
        address follower,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMin,
        uint256 deadline
    ) external nonReentrant whenNotHalted returns (uint256 amountOut, uint256 trailId) {
        if (msg.sender == address(0) || follower == address(0)) revert Roo_ZeroAddress();
        if (tokenIn == address(0) || tokenOut == address(0)) revert Roo_ZeroAddress();
        if (amountIn == 0) revert Roo_ZeroAmount();

        uint256 sid = activeSessionId[follower][msg.sender];
        if (sid == 0) revert Roo_NotEnrolled();
        MirrorSession storage s = mirrorSessions[sid];
        if (!s.active) revert Roo_NotEnrolled();
        if (s.usedAllocWei + amountIn > s.maxAllocWei) revert Roo_AllocExceeded();
        if (block.number < lastTrailBlockByLeader[msg.sender] + TRAIL_COOLDOWN_BLOCKS) revert Roo_CooldownActive();

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        uint256 feeWei = (amountIn * MIRROR_FEE_BPS) / BPS_BASE;
        uint256 amountInAfterFee = amountIn - feeWei;

        IERC20Min(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        if (feeWei > 0) {
            bool ok = IERC20Min(tokenIn).transfer(feeVault, feeWei);
            if (!ok) revert Roo_TransferOutFailed();
        }

        IERC20Min(tokenIn).approve(router, amountInAfterFee);
        uint256 balanceBefore = IERC20Min(tokenOut).balanceOf(follower);

        try IRouterMin(router).swapExactTokensForTokens(
            amountInAfterFee,
            amountOutMin,
            path,
            follower,
            deadline
        ) returns (uint256[] memory amounts) {
            amountOut = amounts[amounts.length - 1];
        } catch {
            IERC20Min(tokenIn).approve(router, 0);
            revert Roo_RouterCallFailed();
        }

        IERC20Min(tokenIn).approve(router, 0);
        uint256 balanceAfter = IERC20Min(tokenOut).balanceOf(follower);
        if (balanceAfter <= balanceBefore) revert Roo_TransferOutFailed();
        amountOut = balanceAfter - balanceBefore;

        s.usedAllocWei += amountIn;
        uint256 lid = leaderIdByAddress[msg.sender];
        if (lid != 0) leaderProfiles[lid].totalVolumeIn += amountIn;
        lastTrailBlockByLeader[msg.sender] = block.number;

        trailId = ++trailCounter;
        trailRecords[trailId] = TrailRecord({
            leader: msg.sender,
            follower: follower,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            amountOut: amountOut,
            atBlock: block.number
        });
        trailIdsByLeader[msg.sender].push(trailId);
        trailIdsByFollower[follower].push(trailId);
        emit TrailExecuted(msg.sender, follower, tokenIn, tokenOut, amountIn, amountOut, trailId, block.number);
        return (amountOut, trailId);
    }

    function executeTrailBatch(
        address[] calldata followers,
        address[] calldata tokensIn,
        address[] calldata tokensOut,
        uint256[] calldata amountsIn,
        uint256[] calldata amountsOutMin,
        uint256 deadline
    ) external nonReentrant whenNotHalted returns (uint256 executedCount, uint256 fromTrailId) {
