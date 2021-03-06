pragma solidity ^0.4.21;

import "../math/SafeMath.sol";
import "../ownership/Ownable.sol";
import "../token/PausableToken.sol";


/**
 * @title StandardTokenCrowdsale
 * @dev StandardTokenCrowdsale is a base contract for managing a token crowdsale,
 * allowing investors to purchase tokens with ether. This contract implements
 * such functionality in its most fundamental form and can be extended to provide additional
 * functionality and/or custom behavior.
 * The external interface represents the basic interface for purchasing tokens, and conform
 * the base architecture for crowdsales. They are *not* intended to be modified / overriden.
 * The internal interface conforms the extensible and modifiable surface of crowdsales. Override
 * the methods to add functionality. Consider using 'super' where appropiate to concatenate
 * behavior.
 * @dev StandardTokenCrowdsale is from OpenZeppelin's Crowdsale with some minor changes
 * mirroring Request Network's StandardCrowdsale and other OpenZeppelin's crowd sales:
 * - TimedCrowdSale to manage crowd sale time
 * - FinalizableCrowdsale to make this a refundable crowd sale.
 */
contract StandardTokenCrowdsale is Ownable
{
    using SafeMath for uint256;

    // The token being sold
    PausableToken public token;

    // Address where funds are collected
    address public wallet;

    // How many token units a buyer gets per wei
    uint256 public rate;

    // Amount of wei raised
    uint256 public weiRaised;

    // Start timestamp of token sale
    uint256 public startTime;

    // End timestamp of token sale
    uint256 public endTime;

    // Boolean flag indicating whether crowd sale is finalized
    bool public isFinalized = false;

    /**
     * Event for token purchase logging
     * @param purchaser who paid for the tokens
     * @param beneficiary who got the tokens
     * @param value weis paid for purchase
     * @param amount amount of tokens purchased
     */
    event TokenPurchase(address indexed purchaser, address indexed beneficiary, uint256 value, uint256 amount);

    /**
     * Event for crowd sale finalization. From OpenZeppelin's FinalizableCrowdsale.
     */
    event Finalized();

    /**
     * @param _startTime Start timestamp of token sale
     * @param _endTime End timestamp of token sale
     * @param _rate Number of token units a buyer gets per wei
     * @param _wallet Address where collected funds will be forwarded to
     */
    function StandardTokenCrowdsale(
        uint256 _startTime,
        uint256 _endTime,
        uint256 _rate,
        address _wallet) public
    {
        require(_startTime >= now);
        require(_endTime >= _startTime);
        require(_rate > 0);
        require(_wallet != address(0));

        startTime = _startTime;
        endTime = _endTime;
        rate = _rate;
        wallet = _wallet;
        token = createTokenContract();
    }

    // -----------------------------------------
    // StandardTokenCrowdsale external interface
    // -----------------------------------------

    /**
     * @dev fallback function ***DO NOT OVERRIDE***
     */
    function () external payable
    {
        buyTokens(msg.sender);
    }

    /**
     * @dev low level token purchase ***DO NOT OVERRIDE***
     * @param _beneficiary Address performing the token purchase
     */
    function buyTokens(address _beneficiary) public payable
    {
        uint256 weiAmount = msg.value;
        _preValidatePurchase(_beneficiary, weiAmount);

        // calculate token amount to be created
        uint256 baseTokens = _getTokenAmount(weiAmount);
        uint256 bonusTokens = _getBonusTokenAmount(weiAmount);

        uint256 totalTokens = baseTokens.add(bonusTokens);

        // update state
        weiRaised = weiRaised.add(weiAmount);

        _processPurchase(_beneficiary, totalTokens, bonusTokens);
        emit TokenPurchase(msg.sender, _beneficiary, weiAmount, totalTokens);

        _updatePurchasingState(_beneficiary, weiAmount);

        _forwardFunds();
        _postValidatePurchase(_beneficiary, weiAmount);
    }

    /**
     * @dev Determines if token sale has ended.
     */
    function hasEnded() public constant returns(bool) {
        // solium-disable-next-line security/no-block-members
        return now > endTime;
    }

    /**
     * @dev Reverts if not in crowdsale time range.
     * @dev From OpenZeppelin's TimedCrowdSale.
     */
    modifier onlyWhileOpen {
        // solium-disable-next-line security/no-block-members
        require(block.timestamp >= startTime && block.timestamp <= endTime);
        _;
    }

    /**
     * @dev Checks whether the period in which the crowdsale is open has already elapsed.
     * From OpenZeppelin's TimedCrowdSale.
     * @return Whether crowdsale period has elapsed
     */
    function hasClosed() public view returns (bool) {
        // solium-disable-next-line security/no-block-members
        return block.timestamp > endTime;
    }

    /**
     * @dev Must be called after crowdsale ends, to do some extra finalization
     * work. Calls the contract's finalization function. From OpenZeppelin's FinalizableCrowdsale
     */
    function finalize() onlyOwner public {
        require(!isFinalized);
        require(hasClosed());

        finalization();
        emit Finalized();

        isFinalized = true;
    }

    // -----------------------------------------
    // Internal interface (extensible)
    // -----------------------------------------

    /**
     * @dev Create token contract. Override this method to create custom token for token sale. Based on Request Network code.
     */
    function createTokenContract() internal returns(PausableToken) {
        return new PausableToken();
    }

    /**
     * @dev Validation of an incoming purchase. Use require statements to revert state when conditions are not met. Use super to concatenate validations.
     * @param _beneficiary Address performing the token purchase
     * @param _weiAmount Value in wei involved in the purchase
     */
    function _preValidatePurchase(address _beneficiary, uint256 _weiAmount) internal view onlyWhileOpen {
        require(_beneficiary != address(0));
        require(_weiAmount != 0);
        
        // Token can only be purchased during token sale period
        require(now >= startTime);
        require(now <= endTime);
    }

    /**
     * @dev Validation of an executed purchase. Observe state and use revert statements to undo rollback when valid conditions are not met.
     */
    function _postValidatePurchase(address /* _beneficiary */, uint256 /* _weiAmount */) internal pure {
        // optional override
    }

    /**
     * @dev Source of tokens. Override this method to modify the way in which the crowdsale ultimately gets and sends its tokens.
     * @param _beneficiary Address performing the token purchase
     * @param _tokenAmount Number of tokens to be emitted
     * @param _tokenAmount Number of bonus tokens rewarded as crowd sale bonus, will be frozen for 60 days.
     */
    function _deliverTokens(address _beneficiary, uint256 _tokenAmount, uint256 _bonusAmount) internal
    {
        token.increaseFrozen(_beneficiary, _bonusAmount);
        token.transfer(_beneficiary, _tokenAmount);
    }

    /**
     * @dev Executed when a purchase has been validated and is ready to be executed. Not necessarily emits/sends tokens.
     * @param _beneficiary Address receiving the tokens
     * @param _tokenAmount Number of tokens to be purchased
     * @param _tokenAmount Number of bonus tokens rewarded as crowd sale bonus, will be frozen for 60 days.
     */
    function _processPurchase(address _beneficiary, uint256 _tokenAmount, uint256 _bonusAmount) internal {
        _deliverTokens(_beneficiary, _tokenAmount, _bonusAmount);
    }

    /**
     * @dev Override for extensions that require an internal state to check for validity (current user contributions, etc.)
     */
    function _updatePurchasingState(address /* _beneficiary */, uint256 /* _weiAmount */) internal {
        // optional override
    }

    /**
     * @dev Override to extend the way in which ether is converted to tokens.
     * @param _weiAmount Value in wei to be converted into tokens
     * @return Number of tokens that can be purchased with the specified _weiAmount
     */
    function _getTokenAmount(uint256 _weiAmount) internal view returns (uint256)
    {
        return _weiAmount.mul(rate);
    }

    /**
     * @dev Override to extend the way we determine bonus token amount.
     * @return Number of bonus tokens that will be awarded for a purchase of _weiAmount
     * @dev Agon changes
     */
    function _getBonusTokenAmount(uint256 /* _weiAmount */) internal view returns (uint256)
    {
        return 0;
    }

    /**
     * @dev Determines how ETH is stored/forwarded on purchases.
     */
    function _forwardFunds() internal
    {
        wallet.transfer(msg.value);
    }

    /**
     * @dev Can be overridden to add finalization logic. The overriding function
     * should call super.finalization() to ensure the chain of finalization is
     * executed entirely.
     */
    function finalization() internal {
    }

}