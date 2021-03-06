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
import "./LiquidityToken.sol";
import "./OptionGreekCache.sol";
import "./OptionMarket.sol";
import "./libraries/PoolHedger.sol";

/**
 * @title LiquidityPool
 * @author Lyra
 * @dev Holds funds from LPs, which are used for the following purposes:
 * 1. Collateralizing options sold by the OptionMarket.
 * 2. Buying options from users.
 * 3. Delta hedging the LPs.
 * 4. Storing funds for expired in the money options.
 */
contract LiquidityPool is Owned, SimpleInitializeable, ReentrancyGuard {
  using DecimalMath for uint;

  struct Collateral {
    uint quote;
    uint base;
  }

  /// These values are all in quoteAsset amounts.
  struct Liquidity {
    // Amount of liquidity available for option collateral and premiums
    uint freeLiquidity;
    // Amount of liquidity available for withdrawals - different to freeLiquidity
    uint burnableLiquidity;
    // Amount of liquidity reserved for long options sold to traders
    uint usedCollatLiquidity;
    // Portion of liquidity reserved for delta hedging (quote outstanding)
    uint pendingDeltaLiquidity;
    // Current value of delta hedge
    uint usedDeltaLiquidity;
    // Net asset value, including everything and netOptionValue
    uint NAV;
  }

  struct QueuedDeposit {
    uint id;
    // Who will receive the LiquidityToken minted for this deposit after the wait time
    address beneficiary;
    // The amount of quoteAsset deposited to be converted to LiquidityToken after wait time
    uint amountLiquidity;
    // The amount of LiquidityToken minted. Will equal to 0 if not processed
    uint mintedTokens;
    uint depositInitiatedTime;
  }

  struct QueuedWithdrawal {
    uint id;
    // Who will receive the quoteAsset returned after burning the LiquidityToken
    address beneficiary;
    // The amount of LiquidityToken being burnt after the wait time
    uint amountTokens;
    // The amount of quote transferred. Will equal to 0 if process not started
    uint quoteSent;
    uint withdrawInitiatedTime;
  }

  struct LiquidityPoolParameters {
    // The minimum amount of quoteAsset for a deposit, or the amount of LiquidityToken for a withdrawal
    uint minDepositWithdraw;
    // Time between initiating a deposit and when it can be processed
    uint depositDelay;
    // Time between initiating a withdrawal and when it can be processed
    uint withdrawalDelay;
    // Fee charged on withdrawn funds
    uint withdrawalFee;
    // Percentage of NAV below which the liquidity CB fires
    uint liquidityCBThreshold;
    // Length of time after the liq. CB stops firing during which deposits/withdrawals are still blocked
    uint liquidityCBTimeout;
    // Difference between the spot and GWAV baseline IVs after which point the vol CB will fire
    uint ivVarianceCBThreshold;
    // Difference between the spot and GWAV skew ratios after which point the vol CB will fire
    uint skewVarianceCBThreshold;
    // Length of time after the (base) vol. CB stops firing during which deposits/withdrawals are still blocked
    uint ivVarianceCBTimeout;
    // Length of time after the (skew) vol. CB stops firing during which deposits/withdrawals are still blocked
    uint skewVarianceCBTimeout;
    // The address of the "guardian"
    address guardianMultisig;
    // Length of time a deposit/withdrawal since initiation for before a guardian can force process their transaction
    uint guardianDelay;
    // When a new board is listed, block deposits/withdrawals
    uint boardSettlementCBTimeout;
    // When exchanging, don't exchange if fee is above this value
    uint maxFeePaid;
  }

  SynthetixAdapter internal synthetixAdapter;
  OptionMarket internal optionMarket;
  LiquidityToken internal liquidityToken;
  ShortCollateral internal shortCollateral;
  OptionGreekCache internal greekCache;
  PoolHedger public poolHedger;
  ERC20 internal quoteAsset;
  ERC20 internal baseAsset;

  mapping(uint => QueuedDeposit) public queuedDeposits;
  /// @dev The total amount of quoteAsset pending deposit (that hasn't entered the pool)
  uint public totalQueuedDeposits = 0;

  /// @dev The next queue item that needs to be processed
  uint public queuedDepositHead = 1;
  uint public nextQueuedDepositId = 1;

  mapping(uint => QueuedWithdrawal) public queuedWithdrawals;
  uint public totalQueuedWithdrawals = 0;

  /// @dev The next queue item that needs to be processed
  uint public queuedWithdrawalHead = 1;
  uint public nextQueuedWithdrawalId = 1;

  /// @dev Parameters relating to depositing and withdrawing from the Lyra LP
  LiquidityPoolParameters public lpParams;

  // timestamp for when deposits/withdrawals will be available to deposit/withdraw
  // This checks if liquidity is all used - adds 3 days to block.timestamp if it is
  // This also checks if vol variance is high - adds 12 hrs to block.timestamp if it is
  uint public CBTimestamp = 0;

  ////
  // Other Variables
  ////
  /// @dev Amount of collateral locked for outstanding calls and puts sold to users
  Collateral public lockedCollateral;
  /// @dev Total amount of quoteAsset reserved for all settled options that have yet to be paid out
  uint public totalOutstandingSettlements;

  /// @dev Total value not transferred to this contract for all shorts that didn't have enough collateral after expiry
  uint public insolventSettlementAmount;
  /// @dev Total value not transferred to this contract for all liquidations that didn't have enough collateral when liquidated
  uint public liquidationInsolventAmount;

  ///////////
  // Setup //
  ///////////

  constructor() Owned() {}

  /// @dev Initialise important addresses for the contract
  function init(
    SynthetixAdapter _synthetixAdapter,
    OptionMarket _optionMarket,
    LiquidityToken _liquidityToken,
    OptionGreekCache _greekCache,
    PoolHedger _poolHedger,
    ShortCollateral _shortCollateral,
    ERC20 _quoteAsset,
    ERC20 _baseAsset
  ) external onlyOwner initializer {
    synthetixAdapter = _synthetixAdapter;
    optionMarket = _optionMarket;
    liquidityToken = _liquidityToken;
    greekCache = _greekCache;
    shortCollateral = _shortCollateral;
    poolHedger = _poolHedger;
    quoteAsset = _quoteAsset;
    baseAsset = _baseAsset;
    synthetixAdapter.delegateApprovals().approveExchangeOnBehalf(address(synthetixAdapter));
  }

  ///////////
  // Admin //
  ///////////

  /// @notice set `LiquidityPoolParameteres`
  function setLiquidityPoolParameters(LiquidityPoolParameters memory _lpParams) external onlyOwner {
    if (
      !(_lpParams.depositDelay < 365 days &&
        _lpParams.withdrawalDelay < 365 days &&
        _lpParams.withdrawalFee < 2e17 &&
        _lpParams.liquidityCBThreshold < 1e18 &&
        _lpParams.liquidityCBTimeout < 60 days &&
        _lpParams.ivVarianceCBTimeout < 60 days &&
        _lpParams.skewVarianceCBTimeout < 60 days &&
        _lpParams.guardianDelay < 365 days &&
        _lpParams.boardSettlementCBTimeout < 10 days)
    ) {
      revert InvalidLiquidityPoolParameters(address(this), _lpParams);
    }

    lpParams = _lpParams;

    emit LiquidityPoolParametersUpdated(lpParams);
  }

  /// @dev Swap out current PoolHedger with a new contract
  function setPoolHedger(PoolHedger newPoolHedger) external onlyOwner {
    poolHedger = newPoolHedger;
    emit PoolHedgerUpdated(poolHedger);
  }

  /// @dev In case of an update to the synthetix contract that revokes the approval
  function updateDelegateApproval() external onlyOwner {
    synthetixAdapter.delegateApprovals().approveExchangeOnBehalf(address(synthetixAdapter));
  }

  //////////////////////////////
  // Deposits and Withdrawals //
  //////////////////////////////

  /**
   * @notice LP will send sUSD into the contract in return for LiquidityToken (representative of their share of the entire pool)
   *         to be given either instantly (if no live boards) or after the delay period passes (including CBs).
   *         This action is not reversible.
   *
   * @param beneficiary will receive the LiquidityToken after the deposit is processed
   * @param amountQuote is the amount of sUSD the LP is depositing
   */
  function initiateDeposit(address beneficiary, uint amountQuote) external nonReentrant {
    if (beneficiary == address(0)) {
      revert InvalidBeneficiaryAddress(address(this), beneficiary);
    }
    if (amountQuote < lpParams.minDepositWithdraw) {
      revert MinimumDepositNotMet(address(this), amountQuote, lpParams.minDepositWithdraw);
    }
    if (optionMarket.getNumLiveBoards() == 0) {
      uint tokenPrice = getTokenPrice();
      uint amountTokens = amountQuote.divideDecimal(tokenPrice);
      liquidityToken.mint(beneficiary, amountTokens);
      emit DepositProcessed(msg.sender, beneficiary, 0, amountQuote, tokenPrice, amountTokens, block.timestamp);
    } else {
      QueuedDeposit storage newDeposit = queuedDeposits[nextQueuedDepositId];

      newDeposit.id = nextQueuedDepositId++;
      newDeposit.beneficiary = beneficiary;
      newDeposit.amountLiquidity = amountQuote;
      newDeposit.depositInitiatedTime = block.timestamp;

      totalQueuedDeposits += amountQuote;

      emit DepositQueued(msg.sender, beneficiary, newDeposit.id, amountQuote, totalQueuedDeposits, block.timestamp);
    }

    if (!quoteAsset.transferFrom(msg.sender, address(this), amountQuote)) {
      revert QuoteTransferFailed(address(this), msg.sender, address(this), amountQuote);
    }
  }

  /**
   * @notice LP instantly burns LiquidityToken, signalling they wish to withdraw
   *         their share of the pool in exchange for quote, to be processed instantly (if no live boards)
   *         or after the delay period passes (including CBs).
   *         This action is not reversible.
   *
   *
   * @param beneficiary will receive sUSD after the withdrawal is processed
   * @param amountLiquidityToken: is the amount of LiquidityToken the LP is withdrawing
   */
  function initiateWithdraw(address beneficiary, uint amountLiquidityToken) external nonReentrant {
    if (beneficiary == address(0)) {
      revert InvalidBeneficiaryAddress(address(this), beneficiary);
    }
    if (amountLiquidityToken < lpParams.minDepositWithdraw) {
      revert MinimumWithdrawNotMet(address(this), amountLiquidityToken, lpParams.minDepositWithdraw);
    }
    if (optionMarket.getNumLiveBoards() == 0) {
      uint tokenPrice = getTokenPrice();
      uint quoteReceived = amountLiquidityToken.multiplyDecimal(tokenPrice);
      _transferQuote(beneficiary, quoteReceived);
      emit WithdrawProcessed(
        msg.sender,
        beneficiary,
        0,
        amountLiquidityToken,
        tokenPrice,
        quoteReceived,
        totalQueuedWithdrawals,
        block.timestamp
      );
    } else {
      QueuedWithdrawal storage newWithdrawal = queuedWithdrawals[nextQueuedWithdrawalId];

      newWithdrawal.id = nextQueuedWithdrawalId++;
      newWithdrawal.beneficiary = beneficiary;
      newWithdrawal.amountTokens = amountLiquidityToken;
      newWithdrawal.withdrawInitiatedTime = block.timestamp;

      totalQueuedWithdrawals += amountLiquidityToken;

      emit WithdrawQueued(
        msg.sender,
        beneficiary,
        newWithdrawal.id,
        amountLiquidityToken,
        totalQueuedWithdrawals,
        block.timestamp
      );
    }
    liquidityToken.burn(msg.sender, amountLiquidityToken);
  }

  /// @param limit number of deposit tickets to process in a single transaction to avoid gas limit soft-locks
  function processDepositQueue(uint limit) external nonReentrant {
    (uint tokenPrice, bool stale, ) = _getTokenPriceAndStale();

    for (uint i = 0; i < limit; ++i) {
      QueuedDeposit storage current = queuedDeposits[queuedDepositHead];
      if (!_canProcess(current.depositInitiatedTime, lpParams.depositDelay, stale, queuedDepositHead)) {
        return;
      }

      uint amountTokens = current.amountLiquidity.divideDecimal(tokenPrice);
      liquidityToken.mint(current.beneficiary, amountTokens);
      current.mintedTokens = amountTokens;
      totalQueuedDeposits -= current.amountLiquidity;

      emit DepositProcessed(
        msg.sender,
        current.beneficiary,
        queuedDepositHead,
        current.amountLiquidity,
        tokenPrice,
        amountTokens,
        block.timestamp
      );
      current.amountLiquidity = 0;

      queuedDepositHead++;
    }
  }

  /// @param limit number of withdrawal tickets to process in a single transaction to avoid gas limit soft-locks
  function processWithdrawalQueue(uint limit) external nonReentrant {
    for (uint i = 0; i < limit; ++i) {
      (uint totalTokensBurnable, uint tokenPriceWithFee, bool stale) = _getTotalBurnableTokens();

      QueuedWithdrawal storage current = queuedWithdrawals[queuedWithdrawalHead];

      if (!_canProcess(current.withdrawInitiatedTime, lpParams.withdrawalDelay, stale, queuedWithdrawalHead)) {
        return;
      }

      if (totalTokensBurnable == 0) {
        return;
      }

      uint burnAmount = current.amountTokens;
      if (burnAmount > totalTokensBurnable) {
        burnAmount = totalTokensBurnable;
      }

      current.amountTokens -= burnAmount;
      totalQueuedWithdrawals -= burnAmount;

      uint quoteAmount = burnAmount.multiplyDecimal(tokenPriceWithFee);
      current.quoteSent += quoteAmount;
      _transferQuote(current.beneficiary, quoteAmount);
      if (current.amountTokens > 0) {
        emit WithdrawPartiallyProcessed(
          msg.sender,
          current.beneficiary,
          queuedWithdrawalHead,
          burnAmount,
          tokenPriceWithFee,
          quoteAmount,
          totalQueuedWithdrawals,
          block.timestamp
        );
        return;
      }
      emit WithdrawProcessed(
        msg.sender,
        current.beneficiary,
        queuedWithdrawalHead,
        burnAmount,
        tokenPriceWithFee,
        quoteAmount,
        totalQueuedWithdrawals,
        block.timestamp
      );
      queuedWithdrawalHead++;
    }
  }

  /// @dev Checks if deposit/withdrawal ticket can be processed
  function _canProcess(
    uint initiatedTime,
    uint minimumDelay,
    bool isStale,
    uint entryId
  ) internal returns (bool) {
    bool validEntry = initiatedTime != 0;
    // bypass circuit breaker and stale checks if the guardian is calling and their delay has passed
    bool guardianBypass = msg.sender == lpParams.guardianMultisig &&
      initiatedTime + lpParams.guardianDelay < block.timestamp;
    // if minimum delay or circuit breaker timeout hasn't passed, we can't process
    bool delaysExpired = initiatedTime + minimumDelay < block.timestamp && CBTimestamp < block.timestamp;

    emit CheckingCanProcess(entryId, !isStale, validEntry, guardianBypass, delaysExpired);

    return validEntry && ((!isStale && delaysExpired) || guardianBypass);
  }

  function _getTotalBurnableTokens()
    internal
    returns (
      uint tokensBurnable,
      uint tokenPriceWithFee,
      bool stale
    )
  {
    uint burnableLiquidity;
    uint tokenPrice;
    (tokenPrice, stale, burnableLiquidity) = _getTokenPriceAndStale();

    if (optionMarket.getNumLiveBoards() != 0) {
      tokenPriceWithFee = tokenPrice.multiplyDecimal(DecimalMath.UNIT - lpParams.withdrawalFee);
    } else {
      tokenPriceWithFee = tokenPrice;
    }

    return (burnableLiquidity.divideDecimal(tokenPriceWithFee), tokenPriceWithFee, stale);
  }

  function _getTokenPriceAndStale()
    internal
    returns (
      uint tokenPrice,
      bool,
      uint burnableLiquidity
    )
  {
    uint spotPrice = synthetixAdapter.getSpotPriceForMarket(address(optionMarket));

    OptionGreekCache.GlobalCache memory globalCache = greekCache.getGlobalCache();
    bool stale = greekCache.isGlobalCacheStale(spotPrice);

    (uint pendingDelta, uint usedDelta) = _getPoolHedgerLiquidity(spotPrice);

    uint totalPoolValue = _getTotalPoolValueQuote(spotPrice, usedDelta, globalCache.netGreeks.netOptionValue);
    uint totalTokenSupply = getTotalTokenSupply();
    tokenPrice = _getTokenPrice(totalPoolValue, totalTokenSupply);

    uint queuedTokenValue = tokenPrice.multiplyDecimal(totalQueuedWithdrawals);

    Liquidity memory liquidity = _getLiquidity(spotPrice, totalPoolValue, queuedTokenValue, usedDelta, pendingDelta);

    _updateCBs(liquidity, globalCache.maxIvVariance, globalCache.maxSkewVariance, globalCache.netGreeks.netOptionValue);

    return (tokenPrice, stale, liquidity.burnableLiquidity);
  }

  //////////////////////
  // Circuit Breakers //
  //////////////////////

  /// @notice Checks the ivVariance, skewVariance, and liquidity circuit breakers and triggers if necessary
  function updateCBs() external nonReentrant {
    uint spotPrice = synthetixAdapter.getSpotPriceForMarket(address(optionMarket));
    OptionGreekCache.GlobalCache memory globalCache = greekCache.getGlobalCache();
    Liquidity memory liquidity = getLiquidity(spotPrice);
    _updateCBs(liquidity, globalCache.maxIvVariance, globalCache.maxSkewVariance, globalCache.netGreeks.netOptionValue);
  }

  function _updateCBs(
    Liquidity memory liquidity,
    uint maxIvVariance,
    uint maxSkewVariance,
    int optionValueDebt
  ) internal {
    // don't trigger CBs if pool has no open options
    if (liquidity.usedCollatLiquidity == 0 && optionValueDebt == 0) {
      return;
    }

    uint timeToAdd = 0;

    // if NAV == 0, openAmount will be zero too and _updateCB() won't be called.
    uint freeLiquidityPercent = liquidity.freeLiquidity.divideDecimal(liquidity.NAV);

    bool ivVarianceThresholdCrossed = maxIvVariance > lpParams.ivVarianceCBThreshold;
    bool skewVarianceThresholdCrossed = maxSkewVariance > lpParams.skewVarianceCBThreshold;
    bool liquidityThresholdCrossed = freeLiquidityPercent < lpParams.liquidityCBThreshold;

    if (ivVarianceThresholdCrossed) {
      timeToAdd = lpParams.ivVarianceCBTimeout;
    }

    if (skewVarianceThresholdCrossed && lpParams.skewVarianceCBTimeout > timeToAdd) {
      timeToAdd = lpParams.skewVarianceCBTimeout;
    }

    if (liquidityThresholdCrossed && lpParams.liquidityCBTimeout > timeToAdd) {
      timeToAdd = lpParams.liquidityCBTimeout;
    }

    if (timeToAdd > 0 && CBTimestamp < block.timestamp + timeToAdd) {
      CBTimestamp = block.timestamp + timeToAdd;
      emit CircuitBreakerUpdated(
        CBTimestamp,
        ivVarianceThresholdCrossed,
        skewVarianceThresholdCrossed,
        liquidityThresholdCrossed
      );
    }
  }

  ///////////////////////
  // Only OptionMarket //
  ///////////////////////

  /**
   * @notice Locks quote as collateral when the AMM sells a put option.
   *
   * @param amount The amount of quote to lock.
   * @param freeLiquidity The amount of free collateral that can be locked.
   */
  function lockQuote(uint amount, uint freeLiquidity) external onlyOptionMarket {
    if (amount > freeLiquidity) {
      revert LockingMoreQuoteThanIsFree(address(this), amount, freeLiquidity, lockedCollateral);
    }
    lockedCollateral.quote += amount;
    emit QuoteLocked(amount, lockedCollateral.quote);
  }

  /**
   * @notice Purchases and locks base as collateral when the AMM sells a call option.
   *
   * @param amount The amount of baseAsset to purchase and lock.
   * @param exchangeParams The exchangeParams.
   * @param freeLiquidity The amount of free collateral that can be locked.
   */
  function lockBase(
    uint amount,
    SynthetixAdapter.ExchangeParams memory exchangeParams,
    uint freeLiquidity
  ) external onlyOptionMarket {
    lockedCollateral.base += amount;
    _maybeExchangeBase(exchangeParams, freeLiquidity, true);
    emit BaseLocked(amount, lockedCollateral.base);
  }

  /**
   * @notice Frees quote collateral when user closes a long put
   *         and sends them the option premium
   *
   * @param amountQuoteFreed The amount of quote to free.
   */
  function freeQuoteCollateralAndSendPremium(
    uint amountQuoteFreed,
    address recipient,
    uint totalCost,
    uint reservedFee
  ) external onlyOptionMarket {
    _freeQuoteCollateral(amountQuoteFreed);
    _sendPremium(recipient, totalCost, reservedFee);
  }

  /**
   * @notice Frees/exchange base collateral when user closes a long call
   *         and sends the option premium to the user
   *
   * @param amountBase The amount of base to free and exchange.
   */
  function liquidateBaseAndSendPremium(
    uint amountBase,
    address recipient,
    uint totalCost,
    uint reservedFee
  ) external onlyOptionMarket {
    _freeBase(amountBase);
    exchangeBase();
    _sendPremium(recipient, totalCost, reservedFee);
  }

  /**
   * @notice Sends premium user selling an option to the pool.
   * @dev The caller must be the OptionMarket.
   *
   * @param recipient The address of the recipient.
   * @param premium The amount to transfer to the user.
   * @param freeLiquidity The amount of free collateral liquidity.
   * @param reservedFee The amount collected by the OptionMarket.
   */
  function sendShortPremium(
    address recipient,
    uint premium,
    uint freeLiquidity,
    uint reservedFee
  ) external onlyOptionMarket {
    if (premium + reservedFee > freeLiquidity) {
      revert SendPremiumNotEnoughCollateral(address(this), premium, reservedFee, freeLiquidity);
    }
    _sendPremium(recipient, premium, reservedFee);
  }

  /**
   * @notice Manages collateral at the time of board liquidation, also converting base received from shortCollateral.
   *
   * @param insolventSettlements amount of AMM profits not paid by shortCollateral due to user insolvencies.
   * @param amountQuoteFreed amount of AMM long put quote collateral that can be freed, including ITM profits.
   * @param amountQuoteReserved amount of AMM quote reserved for long call/put ITM profits.
   * @param amountBaseFreed amount of AMM long call base collateral that can be freed, including ITM profits.
   */
  function boardSettlement(
    uint insolventSettlements,
    uint amountQuoteFreed,
    uint amountQuoteReserved,
    uint amountBaseFreed
  ) external onlyOptionMarket {
    // Update circuit breaker whenever a board is settled, to pause deposits/withdrawals
    // This allows keepers some time to settle insolvent positions
    if (block.timestamp + lpParams.boardSettlementCBTimeout > CBTimestamp) {
      CBTimestamp = block.timestamp + lpParams.boardSettlementCBTimeout;
      emit BoardSettlementCircuitBreakerUpdated(CBTimestamp);
    }

    insolventSettlementAmount += insolventSettlements;

    _freeQuoteCollateral(amountQuoteFreed);
    _freeBase(amountBaseFreed);

    totalOutstandingSettlements += amountQuoteReserved;
    emit BoardSettlement(insolventSettlementAmount, amountQuoteReserved, totalOutstandingSettlements);

    if (address(poolHedger) != address(0)) {
      poolHedger.resetInteractionDelay();
    }
  }

  /**
   * @notice Frees quote when the AMM buys back/settles a put from the user.
   * @param amountQuote The amount of quote to free.
   */
  function _freeQuoteCollateral(uint amountQuote) internal {
    // In case of rounding errors
    amountQuote = amountQuote > lockedCollateral.quote ? lockedCollateral.quote : amountQuote;
    lockedCollateral.quote -= amountQuote;
    emit QuoteFreed(amountQuote, lockedCollateral.quote);
  }

  /**
   * @notice Frees base when the AMM buys back/settles a call from the user.
   * @param amountBase The amount of base to free.
   */

  function _freeBase(uint amountBase) internal {
    // In case of rounding errors
    amountBase = amountBase > lockedCollateral.base ? lockedCollateral.base : amountBase;
    lockedCollateral.base -= amountBase;
    emit BaseFreed(amountBase, lockedCollateral.base);
  }

  /**
   * @notice Sends the premium to a user who is closing a long or opening a short.
   * @dev The caller must be the OptionMarket.
   *
   * @param recipient The address of the recipient.
   * @param recipientAmount The amount to transfer to the recipient.
   * @param optionMarketPortion The fee to transfer to the optionMarket.
   */
  function _sendPremium(
    address recipient,
    uint recipientAmount,
    uint optionMarketPortion
  ) internal {
    _transferQuote(recipient, recipientAmount);
    _transferQuote(address(optionMarket), optionMarketPortion);

    emit PremiumTransferred(recipient, recipientAmount, optionMarketPortion);
  }

  //////////////////////////
  // Only ShortCollateral //
  //////////////////////////

  /**
   * @notice Transfers long option settlement profits to `user`.
   * @dev The caller must be the ShortCollateral.
   *
   * @param user The address of the user to send the quote.
   * @param amount The amount of quote to send.
   */
  function sendSettlementValue(address user, uint amount) external onlyShortCollateral {
    // To prevent any potential rounding errors
    if (amount > totalOutstandingSettlements) {
      amount = totalOutstandingSettlements;
    }
    totalOutstandingSettlements -= amount;
    _transferQuote(user, amount);

    emit OutstandingSettlementSent(user, amount, totalOutstandingSettlements);
  }

  /**
   * @notice Claims AMM profits that were not paid during boardSettlement() due to
   * total quote insolvencies > total solvent quote collateral.
   * @dev The caller must be ShortCollateral.
   *
   * @param spotPrice The current spot price of the base asset.
   * @param amountQuote The amount of quote to send to the LiquidityPool.
   */
  function reclaimInsolventQuote(uint spotPrice, uint amountQuote) external onlyShortCollateral {
    Liquidity memory liquidity = getLiquidity(spotPrice);
    if (amountQuote > liquidity.freeLiquidity) {
      revert NotEnoughFreeToReclaimInsolvency(address(this), amountQuote, liquidity);
    }
    _transferQuote(address(shortCollateral), amountQuote);

    insolventSettlementAmount += amountQuote;

    emit InsolventSettlementAmountUpdated(amountQuote, insolventSettlementAmount);
  }

  /**
   * @notice Claims AMM profits that were not paid during boardSettlement() due to
   * total base insolvencies > total solvent base collateral.
   * @dev The caller must be ShortCollateral.
   *
   * @param exchangeParams synthetix exchange parameters.
   * @param amountBase The amount of base to send to the LiquidityPool.
   */

  function reclaimInsolventBase(SynthetixAdapter.ExchangeParams memory exchangeParams, uint amountBase)
    external
    onlyShortCollateral
  {
    Liquidity memory liquidity = getLiquidity(exchangeParams.spotPrice);
    (uint quoteSpent, ) = synthetixAdapter.exchangeToExactBaseWithLimit(
      exchangeParams,
      address(optionMarket),
      amountBase,
      liquidity.freeLiquidity
    );
    insolventSettlementAmount += quoteSpent;
    // It is better for the contract to revert if there is not enough here (due to rounding) to keep accounting in
    // ShortCollateral correct. baseAsset can be donated (sent) to this contract to allow this to pass.
    if (!baseAsset.transfer(address(shortCollateral), amountBase)) {
      revert BaseTransferFailed(address(this), address(this), address(shortCollateral), amountBase);
    }

    emit InsolventSettlementAmountUpdated(quoteSpent, insolventSettlementAmount);
  }

  //////////////////////////////
  // Getting Pool Token Value //
  //////////////////////////////

  /// @dev Get total number of oustanding LiquidityToken
  function getTotalTokenSupply() public view returns (uint) {
    return liquidityToken.totalSupply() + totalQueuedWithdrawals;
  }

  /**
   * @notice Get current pool token price and check if market conditions warrant an accurate token price
   *
   * @return tokenPrice price of token
   * @return isStale has global cache not been updated in a long time (if stale, greeks may be inaccurate)
   * @return circuitBreakerExpiry expiry timestamp of the CircuitBreaker (if not expired, greeks may be inaccurate)
   */
  function getTokenPriceWithCheck()
    external
    view
    returns (
      uint tokenPrice,
      bool isStale,
      uint circuitBreakerExpiry
    )
  {
    uint spotPrice = synthetixAdapter.getSpotPriceForMarket(address(optionMarket));
    int optionValueDebt = greekCache.getGlobalOptionValue();
    (, uint usedDelta) = _getPoolHedgerLiquidity(spotPrice);
    uint totalPoolValue = _getTotalPoolValueQuote(spotPrice, usedDelta, optionValueDebt);
    uint totalTokenSupply = getTotalTokenSupply();

    tokenPrice = _getTokenPrice(totalPoolValue, totalTokenSupply);
    isStale = greekCache.isGlobalCacheStale(spotPrice);
    return (tokenPrice, isStale, CBTimestamp);
  }

  /// @dev Get current pool token price without market condition check
  function getTokenPrice() public view returns (uint) {
    return _getTokenPrice(getTotalPoolValueQuote(), getTotalTokenSupply());
  }

  function _getTokenPrice(uint totalPoolValue, uint totalTokenSupply) internal pure returns (uint) {
    if (totalTokenSupply == 0) {
      return 1e18;
    }

    return totalPoolValue.divideDecimal(totalTokenSupply);
  }

  ////////////////////////////
  // Getting Pool Liquidity //
  ////////////////////////////

  /// @notice Returns the breakdown of current liquidity usage
  function getCurrentLiquidity() external view returns (Liquidity memory) {
    uint spotPrice = synthetixAdapter.getSpotPriceForMarket(address(optionMarket));
    return getLiquidity(spotPrice);
  }

  /**
   * @notice Same return as `getCurrentLiquidity()` but with manual spot price
   */
  function getLiquidity(uint spotPrice) public view returns (Liquidity memory) {
    // if cache is stale, pendingDelta may be inaccurate
    (uint pendingDelta, uint usedDelta) = _getPoolHedgerLiquidity(spotPrice);
    int optionValueDebt = greekCache.getGlobalOptionValue();
    uint totalPoolValue = _getTotalPoolValueQuote(spotPrice, usedDelta, optionValueDebt);
    uint tokenPrice = _getTokenPrice(totalPoolValue, getTotalTokenSupply());

    return
      _getLiquidity(
        spotPrice,
        totalPoolValue,
        tokenPrice.multiplyDecimal(totalQueuedWithdrawals),
        usedDelta,
        pendingDelta
      );
  }

  /// @dev Gets the current NAV
  function getTotalPoolValueQuote() public view returns (uint) {
    uint spotPrice = synthetixAdapter.getSpotPriceForMarket(address(optionMarket));
    int optionValueDebt = greekCache.getGlobalOptionValue();
    (, uint usedDelta) = _getPoolHedgerLiquidity(spotPrice);

    return _getTotalPoolValueQuote(spotPrice, usedDelta, optionValueDebt);
  }

  function _getTotalPoolValueQuote(
    uint basePrice,
    uint usedDeltaLiquidity,
    int optionValueDebt
  ) internal view returns (uint) {
    int totalAssetValue = SafeCast.toInt256(
      quoteAsset.balanceOf(address(this)) +
        baseAsset.balanceOf(address(this)).multiplyDecimal(basePrice) +
        usedDeltaLiquidity -
        totalOutstandingSettlements -
        totalQueuedDeposits
    );

    // Should not be possible due to being fully collateralised
    if (optionValueDebt > totalAssetValue) {
      revert OptionValueDebtExceedsTotalAssets(address(this), totalAssetValue, optionValueDebt);
    }

    return uint(totalAssetValue - optionValueDebt);
  }

  /**
   * @dev Calculates breakdown of LP liquidity usage.
   *      Accounts for quote needed to buy/lock base in cases where pool is not fully collateralized.
   *      PendingLiquidity never exceeds freeLiquidity (before pendingLiquidity is considered).
   */
  function _getLiquidity(
    uint basePrice,
    uint totalPoolValue,
    uint reservedTokenValue,
    uint usedDelta,
    uint pendingDelta
  ) internal view returns (Liquidity memory) {
    Liquidity memory liquidity;
    liquidity.NAV = totalPoolValue;
    liquidity.usedDeltaLiquidity = usedDelta;
    uint baseBalance = baseAsset.balanceOf(address(this));

    liquidity.usedCollatLiquidity = lockedCollateral.quote;
    uint pendingBaseValue;
    if (baseBalance > lockedCollateral.base) {
      liquidity.usedCollatLiquidity += baseBalance.multiplyDecimal(basePrice);
    } else {
      liquidity.usedCollatLiquidity += lockedCollateral.base.multiplyDecimal(basePrice);
      pendingBaseValue = (lockedCollateral.base - baseBalance).multiplyDecimal(basePrice);
    }

    uint usedQuote = totalOutstandingSettlements + totalQueuedDeposits + lockedCollateral.quote + pendingBaseValue;
    uint totalQuote = quoteAsset.balanceOf(address(this));

    uint availableQuote = totalQuote > usedQuote ? totalQuote - usedQuote : 0;

    liquidity.pendingDeltaLiquidity = availableQuote > pendingDelta ? pendingDelta : availableQuote;

    liquidity.freeLiquidity = availableQuote > (pendingDelta + reservedTokenValue)
      ? availableQuote - (pendingDelta + reservedTokenValue)
      : 0;

    liquidity.burnableLiquidity = availableQuote - liquidity.pendingDeltaLiquidity;

    return liquidity;
  }

  /////////////////////
  // Exchanging Base //
  /////////////////////

  /// @notice Will buy/sell and lock/free base if pool is under or over collateralized
  function exchangeBase() public nonReentrant {
    SynthetixAdapter.ExchangeParams memory exchangeParams = synthetixAdapter.getExchangeParams(address(optionMarket));
    Liquidity memory liquidity = getLiquidity(exchangeParams.spotPrice);
    _maybeExchangeBase(exchangeParams, liquidity.freeLiquidity, false);
  }

  /// @dev Will skip base purchase/locking if snx spot fees exceed `lpParams.maxFeePaid`.
  function _maybeExchangeBase(
    SynthetixAdapter.ExchangeParams memory exchangeParams,
    uint freeLiquidity,
    bool revertBuyOnInsufficientFunds
  ) internal {
    uint currentBaseBalance = baseAsset.balanceOf(address(this));
    if (currentBaseBalance > lockedCollateral.base) {
      // Sell base for quote
      if (exchangeParams.baseQuoteFeeRate > lpParams.maxFeePaid) {
        return;
      }
      uint amountBase = currentBaseBalance - lockedCollateral.base;
      uint quoteReceived = synthetixAdapter.exchangeFromExactBase(address(optionMarket), amountBase);
      emit BaseSold(amountBase, quoteReceived);
    } else if (currentBaseBalance < lockedCollateral.base) {
      // Buy base for quote
      uint amountBase = lockedCollateral.base - currentBaseBalance;
      if (exchangeParams.quoteBaseFeeRate > lpParams.maxFeePaid) {
        uint estimatedExchangeCost = synthetixAdapter.estimateExchangeToExactBase(exchangeParams, amountBase);
        if (revertBuyOnInsufficientFunds && estimatedExchangeCost > freeLiquidity) {
          revert InsufficientFreeLiquidityForBaseExchange(
            address(this),
            amountBase,
            estimatedExchangeCost,
            freeLiquidity
          );
        }
        return;
      }
      (uint quoteSpent, uint baseReceived) = synthetixAdapter.exchangeToExactBaseWithLimit(
        exchangeParams,
        address(optionMarket),
        amountBase,
        revertBuyOnInsufficientFunds ? freeLiquidity : type(uint).max
      );
      emit BasePurchased(quoteSpent, baseReceived);
    }
  }

  //////////
  // Misc //
  //////////

  /// @notice returns the LiquidityPoolParameters struct
  function getLpParams() external view returns (LiquidityPoolParameters memory) {
    return lpParams;
  }

  /// @notice updates `liquidationInsolventAmount` if liquidated position is insolveny
  function updateLiquidationInsolvency(uint insolvencyAmountInQuote) external onlyOptionMarket {
    liquidationInsolventAmount += insolvencyAmountInQuote;
  }

  /**
   * @dev get the total amount of quote used and pending for delta hedging
   *
   * @return pendingDeltaLiquidity The amount of liquidity reserved for delta hedging that hasn't occured yet
   * @return usedDeltaLiquidity The value of the current hedge position (long value OR collateral - short debt)
   */
  function _getPoolHedgerLiquidity(uint basePrice)
    internal
    view
    returns (uint pendingDeltaLiquidity, uint usedDeltaLiquidity)
  {
    if (address(poolHedger) != address(0)) {
      return poolHedger.getHedgingLiquidity(basePrice);
    }
    return (0, 0);
  }

  /**
   * @notice Sends quote to the PoolHedger.
   * @dev Transfer amount up to `pendingLiquidity + freeLiquidity`.
   * The hedger must determine what to do with the amount received.
   *
   * @param spotPrice The spot price of the base asset.
   * @param amount The amount requested by the PoolHedger.
   */
  function transferQuoteToHedge(uint spotPrice, uint amount) external onlyPoolHedger returns (uint) {
    Liquidity memory liquidity = getLiquidity(spotPrice);

    uint available = liquidity.pendingDeltaLiquidity + liquidity.freeLiquidity;

    amount = amount > available ? available : amount;

    _transferQuote(address(poolHedger), amount);

    emit QuoteTransferredToPoolHedger(amount);

    return amount;
  }

  function _transferQuote(address to, uint amount) internal {
    if (amount > 0) {
      if (!quoteAsset.transfer(to, amount)) {
        revert QuoteTransferFailed(address(this), address(this), to, amount);
      }
    }
  }

  ///////////////
  // Modifiers //
  ///////////////

  modifier onlyPoolHedger() {
    if (msg.sender != address(poolHedger)) {
      revert OnlyPoolHedger(address(this), msg.sender, address(poolHedger));
    }
    _;
  }

  modifier onlyOptionMarket() {
    if (msg.sender != address(optionMarket)) {
      revert OnlyOptionMarket(address(this), msg.sender, address(optionMarket));
    }
    _;
  }

  modifier onlyShortCollateral() {
    if (msg.sender != address(shortCollateral)) {
      revert OnlyShortCollateral(address(this), msg.sender, address(shortCollateral));
    }
    _;
  }

  ////////////
  // Events //
  ////////////

  /// @dev Emitted whenever the pool paramters are updated
  event LiquidityPoolParametersUpdated(LiquidityPoolParameters lpParams);

  /// @dev Emitted whenever the poolHedger address is modified
  event PoolHedgerUpdated(PoolHedger poolHedger);

  /// @dev Emitted when quote is locked.
  event QuoteLocked(uint quoteLocked, uint lockedCollateralQuote);

  /// @dev Emitted when quote is freed.
  event QuoteFreed(uint quoteFreed, uint lockedCollateralQuote);

  /// @dev Emitted when base is locked.
  event BaseLocked(uint baseLocked, uint lockedCollateralBase);

  /// @dev Emitted when base is freed.
  event BaseFreed(uint baseFreed, uint lockedCollateralBase);

  /// @dev Emitted when a board is settled.
  event BoardSettlement(uint insolventSettlementAmount, uint amountQuoteReserved, uint totalOutstandingSettlements);

  /// @dev Emitted when reserved quote is sent.
  event OutstandingSettlementSent(address indexed user, uint amount, uint totalOutstandingSettlements);

  /// @dev Emitted whenever quote is exchanged for base
  event BasePurchased(uint quoteSpent, uint baseReceived);

  /// @dev Emitted whenever base is exchanged for quote
  event BaseSold(uint amountBase, uint quoteReceived);

  /// @dev Emitted whenever premium is sent to a trader closing their position
  event PremiumTransferred(address indexed recipient, uint recipientPortion, uint optionMarketPortion);

  /// @dev Emitted whenever quote is sent to the PoolHedger
  event QuoteTransferredToPoolHedger(uint amountQuote);

  /// @dev Emitted whenever the insolvent settlement amount is updated (settlement and excess)
  event InsolventSettlementAmountUpdated(uint amountQuoteAdded, uint totalInsolventSettlementAmount);

  /// @dev Emitted whenever a user deposits and enters the queue.
  event DepositQueued(
    address indexed depositor,
    address indexed beneficiary,
    uint indexed depositQueueId,
    uint amountDeposited,
    uint totalQueuedDeposits,
    uint timestamp
  );

  /// @dev Emitted whenever a deposit gets processed. Note, can be processed without being queued.
  ///  QueueId of 0 indicates it was not queued.
  event DepositProcessed(
    address indexed caller,
    address indexed beneficiary,
    uint indexed depositQueueId,
    uint amountDeposited,
    uint tokenPrice,
    uint tokensReceived,
    uint timestamp
  );

  /// @dev Emitted whenever a deposit gets processed. Note, can be processed without being queued.
  ///  QueueId of 0 indicates it was not queued.
  event WithdrawProcessed(
    address indexed caller,
    address indexed beneficiary,
    uint indexed withdrawalQueueId,
    uint amountWithdrawn,
    uint tokenPrice,
    uint quoteReceived,
    uint totalQueuedWithdrawals,
    uint timestamp
  );
  event WithdrawPartiallyProcessed(
    address indexed caller,
    address indexed beneficiary,
    uint indexed withdrawalQueueId,
    uint amountWithdrawn,
    uint tokenPrice,
    uint quoteReceived,
    uint totalQueuedWithdrawals,
    uint timestamp
  );
  event WithdrawQueued(
    address indexed withdrawer,
    address indexed beneficiary,
    uint indexed withdrawalQueueId,
    uint amountWithdrawn,
    uint totalQueuedWithdrawals,
    uint timestamp
  );

  /// @dev Emitted whenever the CB timestamp is updated
  event CircuitBreakerUpdated(
    uint newTimestamp,
    bool ivVarianceThresholdCrossed,
    bool skewVarianceThresholdCrossed,
    bool liquidityThresholdCrossed
  );

  /// @dev Emitted whenever the CB timestamp is updated from a board settlement
  event BoardSettlementCircuitBreakerUpdated(uint newTimestamp);

  /// @dev Emitted whenever a queue item is checked for the ability to be processed
  event CheckingCanProcess(uint entryId, bool boardNotStale, bool validEntry, bool guardianBypass, bool delaysExpired);

  ////////////
  // Errors //
  ////////////
  // Admin
  error InvalidLiquidityPoolParameters(address thrower, LiquidityPoolParameters lpParams);

  // Deposits and withdrawals
  error InvalidBeneficiaryAddress(address thrower, address beneficiary);
  error MinimumDepositNotMet(address thrower, uint amountQuote, uint minDeposit);
  error MinimumWithdrawNotMet(address thrower, uint amountLiquidityToken, uint minWithdraw);

  // Liquidity and accounting
  error LockingMoreQuoteThanIsFree(address thrower, uint quoteToLock, uint freeLiquidity, Collateral lockedCollateral);
  error SendPremiumNotEnoughCollateral(address thrower, uint premium, uint reservedFee, uint freeLiquidity);
  error NotEnoughFreeToReclaimInsolvency(address thrower, uint amountQuote, Liquidity liquidity);
  error OptionValueDebtExceedsTotalAssets(address thrower, int totalAssetValue, int optionValueDebt);
  error InsufficientFreeLiquidityForBaseExchange(
    address thrower,
    uint pendingBase,
    uint estimatedExchangeCost,
    uint freeLiquidity
  );

  // Access
  error OnlyPoolHedger(address thrower, address caller, address poolHedger);
  error OnlyOptionMarket(address thrower, address caller, address optionMarket);
  error OnlyShortCollateral(address thrower, address caller, address poolHedger);

  // Token transfers
  error QuoteTransferFailed(address thrower, address from, address to, uint amount);
  error BaseTransferFailed(address thrower, address from, address to, uint amount);
}
