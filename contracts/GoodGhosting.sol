// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.6.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

/**
 * Play the save game.
 *
 * No SafeMath was used (yet) to shortcut the hacking time.
 *
 * Short game duration for testing purposes
 *
 * Arguments to pass while deploing on Kovan: 0xFf795577d9AC8bD7D90Ee22b6C1703490b6512FD, 0x58AD4cB396411B691A9AAb6F74545b2C5217FE6a, 0x506B0B2CF20FAA8f38a4E2B524EE43e1f4458Cc5
 */

contract GoodGhosting is Ownable, Pausable {
    using SafeMath for uint256;

    // Controls if tokens were redeemed or not from the pool
    bool public redeemed = false;
    // Controls if withdraw amounts were allocated
    bool public withdrawAmountAllocated = false;
    // Stores the total amount of interest received in the game.
    uint public totalGameInterest = 0;
    //  total principal amount
    uint public totalGamePrincipal = 0;

    // Token that players use to buy in the game - DAI
    IERC20 public daiToken;
    // Pointer to aDAI
    AToken public adaiToken;
    // Which Aave instance we use to swap DAI to interest bearing aDAI
    ILendingPoolAddressesProvider public lendingPoolAddressProvider;

    uint public segmentPayment;
    uint public lastSegment;
    uint public firstSegmentStart;
    uint public segmentLength;

    struct Player {
        address addr;
        uint mostRecentSegmentPaid;
        uint amountPaid;
        uint withdrawAmount;
    }
    mapping(address => Player)public players;
    address[] public iterablePlayers;
    address[] public winners;


    event JoinedGame(address indexed player, uint amount);
    event Deposit(address indexed player, uint indexed segment, uint amount);
    event Withdrawal(address indexed player, uint amount);
    event FundsRedeemedFromExternalPool(uint totalAmount, uint totalGamePrincipal, uint totalGameInterest);
    event WinnersAnnouncement(address[] winners);

    modifier whenGameIsCompleted() {
        // Game is completed when the current segment is greater than "lastSegment" of the game.
        // since 0 -> 1 is also 1 segment
        require(getCurrentSegment() > lastSegment.sub(1), 'Game is not completed');
        _;
    }

    modifier whenGameIsNotCompleted() {
        // Game is not completed when current segment is less "lastSegment" of the game.
        require(getCurrentSegment() < lastSegment, 'Game is already completed');
        _;
    }

    modifier afterRedeemedFromExternalPool() {
        require(redeemed, 'Funds not redeemed from external pool yet');
        _;
    }

    /**
        Creates a new instance of GoogGhosting game
        @param _inboundCurrency Smart contract address of inbound currency used for the game.
        @param _interestCurrency Smart contract address of interest currency used for the game.
        @param _lendingPoolAddressProvider Smart contract address of the lending pool adddress provider.
        @param _segmentCount Number of segments in the game.
        @param _segmentLength Lenght of each segment, in seconds (i.e., 180 (sec) => 3 minutes).
        @param _segmentPayment Amount of tokens each player needs to contribute per segment (i.e. 10*10**18 equals to 10 DAI - note that DAI uses 18 decimal places).
     */
    constructor(
        IERC20 _inboundCurrency,
        AToken _interestCurrency,
        ILendingPoolAddressesProvider _lendingPoolAddressProvider,
        uint _segmentCount,
        uint _segmentLength,
        uint _segmentPayment
    ) public {
        // Initializes default variables
        firstSegmentStart = block.timestamp;  //gets current time
        lastSegment = _segmentCount;
        segmentLength = _segmentLength;
        segmentPayment = _segmentPayment;
        daiToken = _inboundCurrency;
        adaiToken = _interestCurrency;
        lendingPoolAddressProvider = _lendingPoolAddressProvider;

        // Allows the lending pool to convert DAI deposited on this contract to aDAI on lending pool
        uint MAX_ALLOWANCE = 2**256 - 1;
        address core = lendingPoolAddressProvider.getLendingPoolCore();
        daiToken.approve(core, MAX_ALLOWANCE);
    }

    function pause() public onlyOwner whenNotPaused {
        _pause();
    }

    function unpause() public onlyOwner whenPaused {
        _unpause();
    }

    function _transferDaiToContract() internal {

        // users pays dai in to the smart contract, which he pre-approved to spend the DAI for him
        // convert DAI to aDAI using the lending pool
        ILendingPool lendingPool = ILendingPool(lendingPoolAddressProvider.getLendingPool());
        // this doesn't make sense since we are already transferring
        require(daiToken.allowance(msg.sender, address(this)) >= segmentPayment , "You need to have allowance to do transfer DAI on the smart contract");

        uint currentSegment = getCurrentSegment();

        players[msg.sender].mostRecentSegmentPaid = currentSegment;
        players[msg.sender].amountPaid = players[msg.sender].amountPaid.add(segmentPayment);
        totalGamePrincipal = totalGamePrincipal.add(segmentPayment);

        // SECURITY NOTE:
        // Interacting with the external contracts should be the last action in the logic to avoid re-entracy attacks.
        // Re-entrancy: https://solidity.readthedocs.io/en/v0.6.12/security-considerations.html#re-entrancy
        // Check-Effects-Interactions Pattern: https://solidity.readthedocs.io/en/v0.6.12/security-considerations.html#use-the-checks-effects-interactions-pattern
        require(daiToken.transferFrom(msg.sender, address(this), segmentPayment), "Transfer failed");
        // lendPool.deposit does not currently return a value,
        // so it is not possible use a require statement to check.
        // if it doesn't revert, we assume it's successful
        lendingPool.deposit(address(daiToken), segmentPayment, 0);
    }

    /**
        Returns the current segment of the game using a 0-based index (returns 0 for the 1st segment ).
        @dev solidity does not return floating point numbers this will always return a whole number
     */
    function getCurrentSegment() view public returns (uint){
       return block.timestamp.sub(firstSegmentStart).div(segmentLength);
    }

    function joinGame() external whenNotPaused {
        require(now < firstSegmentStart + segmentLength, "game has already started");
        require(players[msg.sender].addr != msg.sender, "The player should not have joined the game before");
        Player memory newPlayer = Player({
            addr : msg.sender,
            mostRecentSegmentPaid : 0,
            amountPaid : 0,
            withdrawAmount: 0
        });
        players[msg.sender] = newPlayer;
        iterablePlayers.push(msg.sender);
        // for first segment
        _transferDaiToContract();
        emit JoinedGame(msg.sender, segmentPayment);
    }

    /**
        Reedems funds from external pool and calculates total amount of interest for the game.
        @dev This method only redeems funds from the external pool, without doing any allocation of balances
             to users. This helps to prevent running out of gas and having funds locked into the external pool.
    */
    function redeemFromExternalPool() external whenGameIsCompleted {
        require(!redeemed, "Redeem operation already happened for the game");
        // aave has 1:1 peg for tokens and atokens
        uint adaiBalance = AToken(adaiToken).balanceOf(address(this));
        redeemed = true;
        AToken(adaiToken).redeem(adaiBalance);
        uint totalBalance = IERC20(daiToken).balanceOf(address(this));
        // recording principal amount separately since adai balance will have interest has well
        totalGameInterest = totalBalance.sub(totalGamePrincipal);
        emit FundsRedeemedFromExternalPool(totalBalance, totalGamePrincipal, totalGameInterest);
    }

    /**
        Calculates the withdraw amount each user is entitled to.
        @dev Non-winners can withdraw their principal. Winners can withdraw their principal + interest;
     */
    function allocateWithdrawAmounts() external afterRedeemedFromExternalPool {
        require(!withdrawAmountAllocated, "Withdraw amounts already allocated for players");

        for(uint i = 0; i < iterablePlayers.length; i++) {
            Player storage player = players[iterablePlayers[i]];
            // For winners, we add them to the winner's array so we can later calculate the total
            // amount winners can withdraw (principal + interest).
            // For non-winners, we already have their principal amount stored in state(amountPaid),
            // so we just set this amount to the withdrawAmount.
            if (player.mostRecentSegmentPaid == lastSegment.sub(1)) {
                winners.push(player.addr);
            } else {
                player.withdrawAmount = player.amountPaid;
            }
        }
        // Splits the interest amont between winners.
        uint interestAmtForWinners = 0;
        if (winners.length > 0) {
            // Avoids reverting due to division by zero
            interestAmtForWinners = totalGameInterest.div(winners.length);
        }
        // Calculates the total amount winners can withdraw (principal + interest).
        for (uint j = 0; j < winners.length; j++) {
            Player storage winner = players[winners[j]];
            // For winners, we add the interest to their principal (amountPaid)
            winner.withdrawAmount  = winner.amountPaid.add(interestAmtForWinners);
        }
        withdrawAmountAllocated = true;
        emit WinnersAnnouncement(winners);
    }

    // to be called by individual players to get the amount back once it is redeemed following the solidity withdraw pattern
    function withdraw() external {
        uint amount = players[msg.sender].withdrawAmount;
        require(amount > 0, 'No balance available for withdrawal');
        players[msg.sender].withdrawAmount = 0;
        IERC20(daiToken).transfer(msg.sender, amount);
        emit Withdrawal(msg.sender, amount);
    }
 

    function makeDeposit() external whenNotPaused whenGameIsNotCompleted {
        // only registered players can deposit
        require(players[msg.sender].addr == msg.sender, "Sender is not a player");
        
        uint currentSegment = getCurrentSegment();
        // should not be stagging segment
        require(currentSegment > 0, "Deposits start after the first segment");

        //check if current segment is currently unpaid
        require(players[msg.sender].mostRecentSegmentPaid != currentSegment, "Player already paid current segment");

        //check player has made payments up to the previous segment
        // currentSegment will return 1 when the user pays for current segment
        if (currentSegment != 1) {
           require(players[msg.sender].mostRecentSegmentPaid == (currentSegment.sub(1)),
           "Player didn't pay the previous segment - game over!"
        );
        }
        //💰allow deposit to happen
        _transferDaiToContract();
        emit Deposit(msg.sender, currentSegment, segmentPayment);
    }

}

/*/ For quick testing via Remix, removed contract dependencies and just included them here
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../aave/ILendingPoolAddressesProvider.sol";
import "../aave/ILendingPool.sol";
/*/

abstract contract ILendingPool {
    function deposit(address _reserve, uint256 _amount, uint16 _referralCode) public virtual;
}

interface AToken {
    function redeem(uint256 _amount) external;
    
    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);
}


/**
@title ILendingPoolAddressesProvider interface
@notice provides the interface to fetch the LendingPoolCore address
 */

abstract contract ILendingPoolAddressesProvider {

    function getLendingPool() public virtual view returns (address);
    function setLendingPoolImpl(address _pool) public virtual;

    function getLendingPoolCore() public virtual view returns (address payable);
    function setLendingPoolCoreImpl(address _lendingPoolCore) public virtual;

    function getLendingPoolConfigurator() public virtual view returns (address);
    function setLendingPoolConfiguratorImpl(address _configurator) public virtual;

    function getLendingPoolDataProvider() public virtual view returns (address);
    function setLendingPoolDataProviderImpl(address _provider) public virtual;

    function getLendingPoolParametersProvider() public virtual view returns (address);
    function setLendingPoolParametersProviderImpl(address _parametersProvider) public virtual;

    function getTokenDistributor() public virtual view returns (address);
    function setTokenDistributor(address _tokenDistributor) public virtual;


    function getFeeProvider() public virtual view returns (address);
    function setFeeProviderImpl(address _feeProvider) public virtual;

    function getLendingPoolLiquidationManager() public virtual view returns (address);
    function setLendingPoolLiquidationManager(address _manager) public virtual;

    function getLendingPoolManager() public virtual view returns (address);
    function setLendingPoolManager(address _lendingPoolManager) public virtual;

    function getPriceOracle() public virtual view returns (address);
    function setPriceOracle(address _priceOracle) public virtual;

    function getLendingRateOracle() public virtual view returns (address);
    function setLendingRateOracle(address _lendingRateOracle) public virtual;

}


/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IERC20 {
    /**
     * @dev Returns the amount of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the amount of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves `amount` tokens from the caller's account to `recipient`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets `amount` as the allowance of `spender` over the caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @dev Moves `amount` tokens from `sender` to `recipient` using the
     * allowance mechanism. `amount` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);
}
