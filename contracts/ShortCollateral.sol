//SPDX-License-Identifier: ISC
pragma solidity 0.8.9;

// Libraries
import "./synthetix/DecimalMath.sol";
// Inherited
import "./synthetix/Owned.sol";
import "./libraries/SimpleInitializeable.sol";
import "openzeppelin-contracts-4.4.1/security/ReentrancyGuard.sol";
// Interfaces
import "openzeppelin-contracts-4.4.1/token/ERC20/ERC20.sol";
import "./libraries/PoolHedger.sol";
import "./SynthetixAdapter.sol";
import "./LiquidityPool.sol";
import "./OptionMarket.sol";
import "./OptionToken.sol";

/**
 * @title ShortCollateral
 * @author Lyra
 * @dev Holds collateral from users who are selling (shorting) options to the OptionMarket.
 */
contract ShortCollateral is Owned, SimpleInitializeable, ReentrancyGuard {
  using DecimalMath for uint;

  OptionMarket internal optionMarket;
  LiquidityPool internal liquidityPool;
  OptionToken internal optionToken;
  SynthetixAdapter internal synthetixAdapter;
  ERC20 internal quoteAsset;
  ERC20 internal baseAsset;

  // The amount the SC underpaid the LP due to insolvency.
  // The SC will take this much less from the LP when settling insolvent positions.
  uint public LPBaseExcess;
  uint public LPQuoteExcess;

  ///////////
  // Setup //
  ///////////

  constructor() Owned() {}

  /**
   * @dev Initialize the contract.
   */
  function init(
    OptionMarket _optionMarket,
    LiquidityPool _liquidityPool,
    OptionToken _optionToken,
    SynthetixAdapter _synthetixAdapter,
    ERC20 _quoteAsset,
    ERC20 _baseAsset
  ) external onlyOwner initializer {
    optionMarket = _optionMarket;
    liquidityPool = _liquidityPool;
    optionToken = _optionToken;
    synthetixAdapter = _synthetixAdapter;
    quoteAsset = _quoteAsset;
    baseAsset = _baseAsset;

    synthetixAdapter.delegateApprovals().approveExchangeOnBehalf(address(synthetixAdapter));
  }

  ///////////
  // Admin //
  ///////////

  /// @dev In case of an update to the synthetix contract that revokes the approval
  function updateDelegateApproval() external onlyOwner {
    synthetixAdapter.delegateApprovals().approveExchangeOnBehalf(address(synthetixAdapter));
  }

  ////////////////////////////////
  // Collateral/premium sending //
  ////////////////////////////////

  /**
   * @notice Transfers quoteAsset to the recipient. This should only be called by OptionMarket in the following cases:
   * - A short is closed, in which case the premium for the option is sent to the LP
   * - A user reduces their collateral position on a quote collateralized option
   *
   * @param recipient The recipient of the transfer.
   * @param amount The amount to send.
   */
  function sendQuoteCollateral(address recipient, uint amount) external onlyOptionMarket {
    _sendQuoteCollateral(recipient, amount);
  }

  /**
   * @notice Transfers baseAsset to the recipient. This should only be called by OptionMarket when a user is reducing
   * their collateral on a base collateralized option.
   *
   * @param recipient The recipient of the transfer.
   * @param amount The amount to send.
   */
  function sendBaseCollateral(address recipient, uint amount) external onlyOptionMarket {
    _sendBaseCollateral(recipient, amount);
  }

  /**
   * @notice Transfers quote/base fees and remaining collateral when `OptionMarket.liquidatePosition()` called
   * - liquidator: liquidator portion of liquidation fees
   * - LiquidityPool: premium to close position + LP portion of liquidation fees
   * - OptionMarket: SM portion of the liquidation fees
   * - position owner: remaining collateral after all above fees deducted
   *
   * @param trader address of position owner
   * @param liquidator address of liquidator
   * @param optionType OptionType
   * @param liquidationFees fee/collateral distribution as determined by OptionToken
   */
  function routeLiquidationFunds(
    address trader,
    address liquidator,
    OptionMarket.OptionType optionType,
    OptionToken.LiquidationFees memory liquidationFees
  ) external onlyOptionMarket {
    if (optionType == OptionMarket.OptionType.SHORT_CALL_BASE) {
      _sendBaseCollateral(trader, liquidationFees.returnCollateral);
      _sendBaseCollateral(liquidator, liquidationFees.liquidatorFee);
      _exchangeAndSendBaseCollateral(address(optionMarket), liquidationFees.smFee);
      _exchangeAndSendBaseCollateral(address(liquidityPool), liquidationFees.lpFee + liquidationFees.lpPremiums);
    } else {
      // quote collateral
      _sendQuoteCollateral(trader, liquidationFees.returnCollateral);
      _sendQuoteCollateral(liquidator, liquidationFees.liquidatorFee);
      _sendQuoteCollateral(address(optionMarket), liquidationFees.smFee);
      _sendQuoteCollateral(address(liquidityPool), liquidationFees.lpFee + liquidationFees.lpPremiums);
    }
  }

  //////////////////////
  // Board settlement //
  //////////////////////

  /**
   * @notice Transfers quoteAsset and baseAsset to the LiquidityPool on board settlement.
   *
   * @param amountBase The amount of baseAsset to transfer.
   * @param amountQuote The amount of quoteAsset to transfer.
   * @return lpBaseInsolvency total base amount owed to LP but not sent due to large amount of user insolvencies
   * @return lpQuoteInsolvency total quote amount owed to LP but not sent due to large amount of user insolvencies
   */
  function boardSettlement(uint amountBase, uint amountQuote)
    external
    onlyOptionMarket
    returns (uint lpBaseInsolvency, uint lpQuoteInsolvency)
  {
    uint currentBaseBalance = baseAsset.balanceOf(address(this));
    if (amountBase > currentBaseBalance) {
      lpBaseInsolvency = amountBase - currentBaseBalance;
      amountBase = currentBaseBalance;
      LPBaseExcess += lpBaseInsolvency;
    }

    uint currentQuoteBalance = quoteAsset.balanceOf(address(this));
    if (amountQuote > currentQuoteBalance) {
      lpQuoteInsolvency = amountQuote - currentQuoteBalance;
      amountQuote = currentQuoteBalance;
      LPQuoteExcess += lpQuoteInsolvency;
    }

    _sendBaseCollateral(address(liquidityPool), amountBase);
    _sendQuoteCollateral(address(liquidityPool), amountQuote);

    emit BoardSettlementCollateralSent(
      amountBase,
      amountQuote,
      lpBaseInsolvency,
      lpQuoteInsolvency,
      LPBaseExcess,
      LPQuoteExcess
    );

    return (lpBaseInsolvency, lpQuoteInsolvency);
  }

  /////////////////////////
  // Position Settlement //
  /////////////////////////

  /**
   * @notice Routes profits or remaining collateral for settled long and short options.
   *
   * @param positionIds The ids of the relevant OptionTokens.
   */
  function settleOptions(uint[] memory positionIds) external nonReentrant notGlobalPaused {
    // This is how much is missing from the ShortCollateral contract that was claimed by LPs at board expiry
    // We want to take it back when we know how much was missing.
    uint baseInsolventAmount;
    uint quoteInsolventAmount;

    OptionToken.PositionWithOwner[] memory optionPositions = optionToken.getPositionsWithOwner(positionIds);
    optionToken.settlePositions(positionIds);

    uint positionsLength = optionPositions.length;
    for (uint i = 0; i < positionsLength; ++i) {
      OptionToken.PositionWithOwner memory position = optionPositions[i];
      uint settlementAmount;
      uint insolventAmount;
      (uint strikePrice, uint priceAtExpiry, uint ammShortCallBaseProfitRatio) = optionMarket.getSettlementParameters(
        position.strikeId
      );

      if (priceAtExpiry == 0) {
        revert BoardMustBeSettled(address(this), position);
      }

      if (position.optionType == OptionMarket.OptionType.LONG_CALL) {
        settlementAmount = _sendLongCallProceeds(position.owner, position.amount, strikePrice, priceAtExpiry);
      } else if (position.optionType == OptionMarket.OptionType.LONG_PUT) {
        settlementAmount = _sendLongPutProceeds(position.owner, position.amount, strikePrice, priceAtExpiry);
      } else if (position.optionType == OptionMarket.OptionType.SHORT_CALL_BASE) {
        (settlementAmount, insolventAmount) = _sendShortCallBaseProceeds(
          position.owner,
          position.collateral,
          position.amount,
          ammShortCallBaseProfitRatio
        );
        baseInsolventAmount += insolventAmount;
      } else if (position.optionType == OptionMarket.OptionType.SHORT_CALL_QUOTE) {
        (settlementAmount, insolventAmount) = _sendShortCallQuoteProceeds(
          position.owner,
          position.collateral,
          position.amount,
          strikePrice,
          priceAtExpiry
        );
        quoteInsolventAmount += insolventAmount;
      } else {
        // OptionMarket.OptionType.SHORT_PUT_QUOTE
        (settlementAmount, insolventAmount) = _sendShortPutQuoteProceeds(
          position.owner,
          position.collateral,
          position.amount,
          strikePrice,
          priceAtExpiry
        );
        quoteInsolventAmount += insolventAmount;
      }

      emit PositionSettled(
        position.positionId,
        msg.sender,
        position.owner,
        strikePrice,
        priceAtExpiry,
        position.optionType,
        position.amount,
        settlementAmount,
        insolventAmount
      );
    }

    _reclaimInsolvency(baseInsolventAmount, quoteInsolventAmount);
  }

  /// @dev Send quote or base owed to LiquidityPool due to large number of insolvencies
  function _reclaimInsolvency(uint baseInsolventAmount, uint quoteInsolventAmount) internal {
    SynthetixAdapter.ExchangeParams memory exchangeParams = synthetixAdapter.getExchangeParams(address(optionMarket));

    if (LPBaseExcess > baseInsolventAmount) {
      LPBaseExcess -= baseInsolventAmount;
    } else if (baseInsolventAmount > 0) {
      baseInsolventAmount -= LPBaseExcess;
      LPBaseExcess = 0;
      liquidityPool.reclaimInsolventBase(exchangeParams, baseInsolventAmount);
    }

    if (LPQuoteExcess > quoteInsolventAmount) {
      LPQuoteExcess -= quoteInsolventAmount;
    } else if (quoteInsolventAmount > 0) {
      quoteInsolventAmount -= LPQuoteExcess;
      LPQuoteExcess = 0;
      liquidityPool.reclaimInsolventQuote(exchangeParams.spotPrice, quoteInsolventAmount);
    }
  }

  function _sendLongCallProceeds(
    address account,
    uint amount,
    uint strikePrice,
    uint priceAtExpiry
  ) internal returns (uint settlementAmount) {
    settlementAmount = (priceAtExpiry > strikePrice) ? (priceAtExpiry - strikePrice).multiplyDecimal(amount) : 0;
    liquidityPool.sendSettlementValue(account, settlementAmount);
    return settlementAmount;
  }

  function _sendLongPutProceeds(
    address account,
    uint amount,
    uint strikePrice,
    uint priceAtExpiry
  ) internal returns (uint settlementAmount) {
    settlementAmount = (strikePrice > priceAtExpiry) ? (strikePrice - priceAtExpiry).multiplyDecimal(amount) : 0;
    liquidityPool.sendSettlementValue(account, settlementAmount);
    return settlementAmount;
  }

  function _sendShortCallBaseProceeds(
    address account,
    uint userCollateral,
    uint amount,
    uint strikeToBaseReturnedRatio
  ) internal returns (uint settlementAmount, uint insolvency) {
    uint ammProfit = strikeToBaseReturnedRatio.multiplyDecimal(amount);
    (settlementAmount, insolvency) = _getInsolvency(userCollateral, ammProfit);
    _sendBaseCollateral(account, settlementAmount);
    return (settlementAmount, insolvency);
  }

  function _sendShortCallQuoteProceeds(
    address account,
    uint userCollateral,
    uint amount,
    uint strikePrice,
    uint priceAtExpiry
  ) internal returns (uint settlementAmount, uint insolvency) {
    uint ammProfit = (priceAtExpiry > strikePrice) ? (priceAtExpiry - strikePrice).multiplyDecimal(amount) : 0;
    (settlementAmount, insolvency) = _getInsolvency(userCollateral, ammProfit);
    _sendQuoteCollateral(account, settlementAmount);
    return (settlementAmount, insolvency);
  }

  function _sendShortPutQuoteProceeds(
    address account,
    uint userCollateral,
    uint amount,
    uint strikePrice,
    uint priceAtExpiry
  ) internal returns (uint settlementAmount, uint insolvency) {
    uint ammProfit = (priceAtExpiry < strikePrice) ? (strikePrice - priceAtExpiry).multiplyDecimal(amount) : 0;
    (settlementAmount, insolvency) = _getInsolvency(userCollateral, ammProfit);
    _sendQuoteCollateral(account, settlementAmount);
    return (settlementAmount, insolvency);
  }

  function _getInsolvency(uint userCollateral, uint ammProfit)
    internal
    pure
    returns (uint returnCollateral, uint insolvency)
  {
    if (userCollateral >= ammProfit) {
      returnCollateral = userCollateral - ammProfit;
    } else {
      insolvency = ammProfit - userCollateral;
    }
    return (returnCollateral, insolvency);
  }

  ///////////////
  // Transfers //
  ///////////////
  function _sendQuoteCollateral(address recipient, uint amount) internal {
    if (amount == 0) {
      return;
    }

    uint currentBalance = quoteAsset.balanceOf(address(this));

    if (amount > currentBalance) {
      revert OutOfQuoteCollateralForTransfer(address(this), currentBalance, amount);
    }

    if (!quoteAsset.transfer(recipient, amount)) {
      revert QuoteTransferFailed(address(this), address(this), recipient, amount);
    }
    emit QuoteSent(recipient, amount);
  }

  function _sendBaseCollateral(address recipient, uint amount) internal {
    if (amount == 0) {
      return;
    }

    uint currentBalance = baseAsset.balanceOf(address(this));

    if (amount > currentBalance) {
      revert OutOfBaseCollateralForTransfer(address(this), currentBalance, amount);
    }

    if (!baseAsset.transfer(recipient, amount)) {
      revert BaseTransferFailed(address(this), address(this), recipient, amount);
    }
    emit BaseSent(recipient, amount);
  }

  function _exchangeAndSendBaseCollateral(address recipient, uint amountBase) internal {
    if (amountBase == 0) {
      return;
    }

    uint currentBalance = baseAsset.balanceOf(address(this));
    if (amountBase > currentBalance) {
      revert OutOfBaseCollateralForExchangeAndTransfer(address(this), currentBalance, amountBase);
    }

    uint quoteReceived = synthetixAdapter.exchangeFromExactBase(address(optionMarket), amountBase);

    if (!quoteAsset.transfer(recipient, quoteReceived)) {
      revert QuoteTransferFailed(address(this), address(this), recipient, quoteReceived);
    }

    emit BaseExchangedAndQuoteSent(recipient, amountBase, quoteReceived);
  }

  ///////////////
  // Modifiers //
  ///////////////

  modifier onlyOptionMarket() {
    if (msg.sender != address(optionMarket)) {
      revert OnlyOptionMarket(address(this), msg.sender, address(optionMarket));
    }
    _;
  }

  modifier notGlobalPaused() {
    synthetixAdapter.requireNotGlobalPaused(address(optionMarket));
    _;
  }

  ////////////
  // Events //
  ////////////

  /// @dev Emitted when a board is settled
  event BoardSettlementCollateralSent(
    uint amountBaseSent,
    uint amountQuoteSent,
    uint lpBaseInsolvency,
    uint lpQuoteInsolvency,
    uint LPBaseExcess,
    uint LPQuoteExcess
  );

  /**
   * @dev Emitted when an Option is settled.
   */
  event PositionSettled(
    uint indexed positionId,
    address indexed settler,
    address indexed optionOwner,
    uint strikePrice,
    uint priceAtExpiry,
    OptionMarket.OptionType optionType,
    uint amount,
    uint settlementAmount,
    uint insolventAmount
  );

  /**
   * @dev Emitted when quote is sent to either a user or the LiquidityPool
   */
  event QuoteSent(address indexed receiver, uint amount);
  /**
   * @dev Emitted when base is sent to either a user or the LiquidityPool
   */
  event BaseSent(address indexed receiver, uint amount);

  event BaseExchangedAndQuoteSent(address indexed recipient, uint amountBase, uint quoteReceived);

  ////////////
  // Errors //
  ////////////

  // Collateral transfers
  error OutOfQuoteCollateralForTransfer(address thrower, uint balance, uint amount);
  error OutOfBaseCollateralForTransfer(address thrower, uint balance, uint amount);
  error OutOfBaseCollateralForExchangeAndTransfer(address thrower, uint balance, uint amount);

  // Token transfers
  error BaseTransferFailed(address thrower, address from, address to, uint amount);
  error QuoteTransferFailed(address thrower, address from, address to, uint amount);

  // Access
  error BoardMustBeSettled(address thrower, OptionToken.PositionWithOwner position);
  error OnlyOptionMarket(address thrower, address caller, address optionMarket);
}
