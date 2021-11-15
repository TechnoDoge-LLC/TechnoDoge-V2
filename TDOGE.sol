
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.6;


import "./Address.sol";
import "./ERC20.sol";
import "./Context.sol";
import "./Ownable.sol";
import "./SwapInterfaces.sol";

contract TDOGE is ERC20, Ownable {
    using Address for address payable;

    ISwapRouter02 public swapRouter;
    address public swapPair;
    mapping (address => bool) public automatedMarketMakerPairs;    
    
    bool private swapping;
    uint256 public swapTokensAtAmount;

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    
    uint8 private constant BUY = 0;
    uint8 private constant SELL = 1;

    uint256[2] public liquidityFee = [3,3];
    uint256[2] public marketingFee = [3,3];
    uint256[2] public teamFee = [3,3];
    uint256[2] public feeDenominator = [100,100];
    
    uint256 public marketingTokens;
    uint256 public liquidityTokens;
    uint256 public teamTokens;
    
    uint8 public overLiquifiedPercentage = 100;

    address public marketingWallet = 0x4FC756a5868De3d86D9e26FE0e9d1A24266e2F07;
    address public teamWallet = 0xD69eF1893ed7Fd4e09CcB4830a50B3f940C7f532;
    address public lpWallet = 0x9A0111f4eC0F50F55da1e8E6ac1C90A920faAe19;

    mapping (address => bool) public isExcludedFromFees;
    
    event SwapRouterUpdated (address indexed newAddress, address indexed oldAddress);
    event WalletUpdated (string walletName, address indexed newAddress, address indexed oldAddress);
    event OverLiquifiedPercentageUpdated (uint8 oldOverLiquifiedPercentage, uint8 newOverLiquifiedPercentage);
    event ExcludeFromFees (address indexed account, bool isExcluded);
    event SetAutomatedMarketMakerPair (address indexed pair, bool indexed value);
    event SwapTokensAtAmountUpdated (uint256 oldSwapTokensAtAmount, uint256 newSwapTokensAtAmount);
    event FeesUpdated (
        uint8 feeType,
        uint256 oldMarketingFee, 
        uint256 newMarketingFee, 
        uint256 oldLiquidityFee, 
        uint256 newLiquidityFee, 
        uint256 oldTeamFee, 
        uint256 newTeamFee, 
        uint256 oldFeeDenominator, 
        uint256 newFeeDenominator
    );

    constructor() ERC20 ("TechnoDoge", "TDOGE", 18) {
        ISwapRouter02 _swapRouter = ISwapRouter02 (0x10ED43C718714eb63d5aA57B78B54704E256024E);
        swapPair = ISwapFactory (_swapRouter.factory()).createPair (address(this), _swapRouter.WETH());
        swapRouter = _swapRouter;
        setAutomatedMarketMakerPair (swapPair, true);

        // exclude from paying fees
        isExcludedFromFees[owner()] = true;
        isExcludedFromFees[marketingWallet] = true;
        isExcludedFromFees[teamWallet] = true;
        isExcludedFromFees[lpWallet] = true;
        isExcludedFromFees[BURN_ADDRESS] = true;
        isExcludedFromFees[address(this)] = true;

        // _mint is an internal function in ERC20.sol that is only called here, and CANNOT be called ever again
        _mint (owner(), 100_000_000 * 10**decimals());
         swapTokensAtAmount = totalSupply() / 10_000;
    }

    receive() external payable {}
    
    /**
     * @dev Used to airdrop tokens from a wallet to an array of addresses, each of whom should receive different amounts
     * 
     * The wallet used to send the airdropped tokens needs to aprove the TDOGE contract to spend its tokens before 
     * calling this function, else it will fail. The recommended way to do this is to use BSCScan, calling approve 
     * with the contract address as the spender and the total number of tokens to be airdropped as the amount.
     * 
     * N.B Although in this airdrop function all token amounts MUST NOT include decimals, this differs from the approval 
     * process. To send 1 TDOGE you need to approve 1000000000000000000 (1 and 18 zeroes) to account for the number of 
     * decimals, but would call this function with an amount of 1, for example.
     */
    function airdrop (address airdropWallet, address[] calldata airdropRecipients, uint256[] calldata airdropAmountsWithoutDecimals) external onlyOwner {
        excludeFromFees (airdropWallet, true);
        require (airdropRecipients.length == airdropAmountsWithoutDecimals.length, "Length of recipient and amount arrays must be the same");
        
        // airdropWallet needs to have approved the contract address to spend at least the sum of airdropAmounts
        for (uint256 i = 0; i < airdropRecipients.length; i++)
            _transfer (airdropWallet, airdropRecipients[i], airdropAmountsWithoutDecimals[i] * 10**decimals());
    }
    /**
     * @dev Used to airdrop tokens from a wallet to an array of addresses, each of whom should receive the SAME amount
     * 
     * The wallet used to send the airdropped tokens needs to aprove the TDOGE contract to spend its tokens before 
     * calling this function, else it will fail. The recommended way to do this is to use BSCScan, calling approve 
     * with the contract address as the spender and the total number of tokens to be airdropped as the amount.
     * 
     * N.B Although in this airdrop function all token amounts MUST NOT include decimals, this differs from the approval 
     * process. To send 1 TDOGE you need to approve 1000000000000000000 (1 and 18 zeroes) to account for the number of 
     * decimals, but would call this function with an amount of 1, for example.
     */
    function airdrop (address airdropWallet, address[] calldata airdropRecipients, uint256 airdropAmountWithoutDecimals) external onlyOwner {
        excludeFromFees (airdropWallet, true);
        // airdropWallet needs to have approved the contract address to spend at least airdropAmount * number of recipients
        for (uint256 i = 0; i < airdropRecipients.length; i++)
            _transfer (airdropWallet, airdropRecipients[i], airdropAmountWithoutDecimals * 10**decimals());
    }

    /**
     * @dev Used to set the router address for swapping contract-owned tokens to BNB, and for adding liquidity via
     * 
     * You should not change this unless you know what you are doing, as it can cause the contract to fail when 
     * attempting to sell tokens from a non-fee-exempted address
     */
    function updateRouterAddress (address newAddress) external onlyOwner {
        require (newAddress != address(swapRouter), "TDOGE: The router already has that address");
        require (newAddress != address(0), "TDOGE: The router cannot be set to the zero address");
        
        emit SwapRouterUpdated (newAddress, address(swapRouter));
        
        ISwapRouter02 _swapRouter = ISwapRouter02 (newAddress);
        swapPair = ISwapFactory (_swapRouter.factory()).createPair (address(this), _swapRouter.WETH());
        swapRouter = _swapRouter;
    }
    
    /**
     * @dev Any transactions to and from fee-excluded wallets are not subject to a transfer tax.
     * 
     * The contract address must be excluded to prevent the conversion of fees to BNB for marketing 
     * and liquidity provision being taxed. The owner address must also be excluded so they are able 
     * to add initial liquidity 
     */
    function excludeFromFees (address account, bool excluded) public onlyOwner {
        require (isExcludedFromFees[account] != excluded, "TDOGE: Account is already the value of 'excluded'");
        isExcludedFromFees[account] = excluded;

        emit ExcludeFromFees (account, excluded);
    }

    /**
     * @dev Changes the wallet address used for receiving marketing BNB from the contract
     */
    function setMarketingWallet (address newWallet) external onlyOwner {
        require (newWallet != address(0), "TDOGE: Can't set wallet to the zero address");
        
        emit WalletUpdated ("Marketing", marketingWallet, newWallet);
        
        marketingWallet = newWallet;
    }

    /**
     * @dev Changes the wallet address used for receiving team BNB from the contract
     */
    function setTeamWallet (address newWallet) external onlyOwner  {
        require (newWallet != address(0), "TDOGE: Can't set wallet to the zero address");
        
        emit WalletUpdated ("Team", teamWallet, newWallet);
        
        teamWallet = newWallet;
    }

    /**
     * @dev Changes the wallet address used for receiving LP tokens from the contract
     */
    function setLPWallet (address newWallet) external onlyOwner {
        require (newWallet != address(0), "TDOGE: Can't set wallet to the zero address");
        
        emit WalletUpdated ("LP", lpWallet, newWallet);
        
        lpWallet = newWallet;
    }

    /**
     * @dev Sets the max percentage of tokens desired in the liquidity pool 
     */
    function setOverLiquifiedPercentage (uint8 newOverLiquifiedPercentage) external onlyOwner {
        require (newOverLiquifiedPercentage >= 2 && newOverLiquifiedPercentage <= 100, "TDOGE: percentage must be between 3% and 100%");
        
        emit OverLiquifiedPercentageUpdated (overLiquifiedPercentage, newOverLiquifiedPercentage);
        
        overLiquifiedPercentage = newOverLiquifiedPercentage;
    }

    /**
     * @dev Sets the max percentage of tokens desired in the liquidity pool 
     */
    function setSwapTokensAtAmount (uint256 newSwapTokensAtAmount) external onlyOwner {
        require (newSwapTokensAtAmount >= totalSupply() / 1_000_000 && newSwapTokensAtAmount <= totalSupply() / 100, "TDOGE: Swap amount must be between 0.00001% and 1% of total supply");
        
        emit SwapTokensAtAmountUpdated (swapTokensAtAmount, newSwapTokensAtAmount);
        
        swapTokensAtAmount = newSwapTokensAtAmount;
    }

    /**
     * @dev Allows fees for buying TDOGE to be updated, including the fee denominator. This allows fees of fractional 
     * percentages to be set.
     * 
     * For example, to set fees of 5%, 2.5%, and 7.5% you would send the parameters (50, 25, 75, 1000) to the function, as 
     * 75/1000 is 7.5%. All fees share the same denominator.
     * 
     * N.B Total fees are capped at 20% by this function, to protect investors.
     */
    function setBuyFees (uint256 newMarketingFee, uint256 newLiquidityFee, uint256 newTeamFee, uint256 newFeeDenominator) external onlyOwner {
        setFees (newMarketingFee, newLiquidityFee, newTeamFee, newFeeDenominator, BUY);
    }
    
    /**
     * @dev Allows fees for selling TDOGE to be updated, including the fee denominator. This allows fees of fractional 
     * percentages to be set.
     * 
     * For example, to set fees of 5%, 2.5%, and 7.5% you would send the parameters (50, 25, 75, 1000) to the function, as 
     * 75/1000 is 7.5%. All fees share the same denominator.
     * 
     * N.B Total fees are capped at 20% by this function, to protect investors.
     */
    function setSellFees (uint256 newMarketingFee, uint256 newLiquidityFee, uint256 newTeamFee, uint256 newFeeDenominator) external onlyOwner {
        setFees (newMarketingFee, newLiquidityFee, newTeamFee, newFeeDenominator, SELL);
    }

    /**
     * @dev Allows fees to be updated, including the fee denominator. This allows fees of fractional percentages to be set.
     * 
     * For example, to set fees of 5%, 2.5%, and 7.5% you would send the parameters (50, 25, 75, 1000) to the function, as 
     * 75/1000 is 7.5%. All fees share the same denominator.
     * 
     * N.B Total fees are capped at 20% by this function, to protect investors.
     */
    function setFees (uint256 newMarketingFee, uint256 newLiquidityFee, uint256 newTeamFee, uint256 newFeeDenominator, uint8 feeType) private {
        require (newFeeDenominator != 0, "TDOGE: Fee denominator cannot be 0");
        require (newMarketingFee + newLiquidityFee + newTeamFee == 0 || newFeeDenominator / (newMarketingFee + newLiquidityFee + newTeamFee) >= 5, "TDOGE: Total fees must be <= 20%");
        
        emit FeesUpdated (feeType, marketingFee[feeType], newMarketingFee, liquidityFee[feeType], newLiquidityFee, teamFee[feeType], newTeamFee, feeDenominator[feeType], newFeeDenominator);
        
        marketingFee[feeType] = newMarketingFee;
        liquidityFee[feeType] = newLiquidityFee;
        teamFee[feeType] = newTeamFee;
        feeDenominator[feeType] = newFeeDenominator;
    }

    /**
     * @dev Allows LP addresses to be detecgted by the contract, which allows the contract to distinguish a buy or transfer 
     * from a sell. This is important for the successful running of the contract, as it cannot convert tokens to BNB for 
     * marketing, team or liquidity creation on a buy, and it is standard to do this when selling.
     */
    function setAutomatedMarketMakerPair (address pair, bool value) public onlyOwner {
        require (pair != swapPair || value, "TDOGE: The current LP pair cannot be removed from the list of pairs");
        require(automatedMarketMakerPairs[pair] != value, "TDOGE: The pair is already set to that value");
        
        automatedMarketMakerPairs[pair] = value;

        emit SetAutomatedMarketMakerPair (pair, value);
    }

    /**
     * @dev Transfer from sender to receiver, taking fees and swapping contract-owned tokens to BNB for LP, marketing 
     * and team, if appropriate.
     */
    function _transfer (address from, address to, uint256 amount) internal override {
        require (from != address(0), "ERC20: cannot transfer from the zero address");
        require (to != address(0), "ERC20: cannot transfer to the zero address");

        if (amount == 0) {
            super._transfer (from, to, 0);
            return;
        }

        // Swap contract tokens if over the threshold, not buying, and neither sender or receiver are excluded from fees
        if (balanceOf (address(this)) >= swapTokensAtAmount && !swapping && !automatedMarketMakerPairs[from] && !isExcludedFromFees[from] && !isExcludedFromFees[to]) {
            swapping = true;
            swapTokensAndSend (swapTokensAtAmount);
            swapping = false;
        }

        // Take fees if not swapping and neither sender nor receiver are excluded
        if (!swapping && !isExcludedFromFees[from] && !isExcludedFromFees[to]) {
        	uint8 feeType = automatedMarketMakerPairs[from] ? BUY : SELL;
        	uint256 fees = calculateFees (amount, feeType);
        	amount = amount - fees;
            super._transfer (from, address(this), fees);
        }

        super._transfer (from, to, amount);
    }

    /**
     * @dev Calculates fees due to each of marketing, liquidity and team.
     */
    function calculateFees (uint256 amount, uint8 feeType) private returns (uint256) {
        uint256 _marketingTokens = amount * marketingFee[feeType] / feeDenominator[feeType];
        uint256 _liquidityTokens = amount * liquidityFee[feeType] / feeDenominator[feeType];
        uint256 _teamTokens = amount * teamFee[feeType] / feeDenominator[feeType];
        
        marketingTokens += _marketingTokens;
        liquidityTokens += _liquidityTokens;
        teamTokens += _teamTokens;
        return (_marketingTokens + _liquidityTokens + _teamTokens);
        
    }

    /**
     * @dev Converts fee tokens into BNB which is used to add liquidity and send to the marketing and team wallets
     * 
     * N.B any BNB sent to the contract address will be sent by this function to the team wallet
     */
    function swapTokensAndSend (uint256 swapAmount) private {
        uint256 contractTokenBalance = balanceOf (address(this));
        uint256 scaledMarketingTokens = marketingTokens * swapAmount / contractTokenBalance;
        uint256 scaledLiquidityTokens = liquidityTokens * swapAmount / contractTokenBalance;
        uint256 scaledTeamTokens = teamTokens * swapAmount / contractTokenBalance;
        
        // If overliquified then send liquidity funds to team
        if (balanceOf (swapPair) * 100 / totalSupply() > overLiquifiedPercentage) {
            scaledTeamTokens += scaledLiquidityTokens;
            liquidityTokens -= scaledLiquidityTokens;
            scaledLiquidityTokens = 0;
        }
        
        uint256 tokensForLiquidity = scaledLiquidityTokens / 2;
        uint256 tokensForEth = scaledMarketingTokens + scaledLiquidityTokens + scaledTeamTokens - tokensForLiquidity;
        uint256 ethCreated = swapTokensForEth (tokensForEth);
        
        if (tokensForLiquidity > 0)
            ethCreated = addLiquidity (tokensForLiquidity, ethCreated);
        
        if (ethCreated > 0 && scaledMarketingTokens + scaledTeamTokens > 0) {
            uint256 ethForMarketing = ethCreated * scaledMarketingTokens / (scaledMarketingTokens + scaledTeamTokens);
            
            if (ethForMarketing > 0)
                payable(marketingWallet).sendValue (ethForMarketing);
                
            if (address(this).balance > 0)
                payable(teamWallet).sendValue (address(this).balance);
        }
        
        marketingTokens -= scaledMarketingTokens;
        liquidityTokens -= scaledLiquidityTokens;
        teamTokens -= scaledTeamTokens;
    }

    /**
     * @dev Adds tokens and BNB to the liquidity pool, returning any excess BNB to be sent to marketing and team wallets.
     */
    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private returns (uint256) {
        if (tokenAmount == 0 || ethAmount == 0)
            return 0;
            
        _approve (address(this), address(swapRouter), tokenAmount);

        (,uint256 ethFromLiquidity,) = swapRouter.addLiquidityETH { value: ethAmount } (
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            lpWallet,
            block.timestamp
        );
        
        return (ethAmount - ethFromLiquidity);
    }

    /**
     * @dev Swaps TDOGE for BNB to add to the liquidity pool and send funds to team and marketing wallets.
     */
    function swapTokensForEth (uint256 tokenAmount) private returns (uint256) {
        if (tokenAmount == 0)
            return 0;
            
        uint256 initialBalance = address(this).balance;
        
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = swapRouter.WETH();

        _approve (address(this), address(swapRouter), tokenAmount);

        swapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens (
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
        
        return (address(this).balance - initialBalance);
    }
}