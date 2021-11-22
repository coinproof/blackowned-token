// SPDX-License-Identifier: MIT

pragma solidity ^0.8.7;


import "./Address.sol";
import "./ERC20.sol";
import "./IERC20.sol";
import "./IERC20Metadata.sol";
import "./ReentrancyGuard.sol";
import "./Context.sol";
import "./Ownable.sol";
import "./SwapInterfaces.sol";
import "./Shared.sol";

contract BlackOwned is ERC20, Ownable, Shared {
    using Address for address;
    using Address for address payable;

    ISwapRouter02 public uniswapV2Router;
    address public  uniswapV2Pair;

    bool private swapping;

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    
    uint256 public swapTokensAtAmount = 2_000_000 * (10**18);
    uint256 public blacklistTimeout = 30 minutes;
    
    mapping(address => uint256) public isBlacklistedUntil;

    uint256 public liquidityFee = 3;
    uint256 public marketingFee = 3;
    uint256 public blackHiveFee = 3;
    uint256 public feeDenominator = 100;

    uint256 public maxTxAmount;
    uint256 private launchedAt;
    bool public tradingOpened;
    uint256 private antibotEndTime;
    
    
    address public marketingWalletAddress = 0xCa76718F7548F756034DED1167498580CCE5c7DE;
    address public blackHiveAddress = 0xE3F7E68D0E4600e9Bcd1BB478571b5C2F014a21e;

     // exlcude from fees and max transaction amount
    mapping (address => bool) private isExcludedFromFees;


    // store addresses that a automatic market maker pairs. Any transfer *to* these addresses
    // could be subject to a maximum transfer amount
    mapping (address => bool) public automatedMarketMakerPairs;

    event UpdateUniswapV2Router(address indexed newAddress, address indexed oldAddress);
    event ExcludeFromFees(address indexed account, bool isExcluded);
    event ExcludeMultipleAccountsFromFees(address[] accounts, bool isExcluded);
    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);
    event AccidentallySentTokenWithdrawn (address indexed token, address indexed account, uint256 amount);
    event AccidentallySentBNBWithdrawn (address indexed account, uint256 amount);

    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 ethReceived,
        uint256 tokensIntoLiquidity
    );

    constructor() ERC20("Black Owned", "BLKO") {
        ISwapRouter02 _uniswapV2Router = ISwapRouter02(ROUTER);
         // Create a uniswap pair for this new token
        address _uniswapV2Pair = ISwapFactory(_uniswapV2Router.factory()).createPair(address(this), _uniswapV2Router.WETH());

        uniswapV2Router = _uniswapV2Router;
        uniswapV2Pair = _uniswapV2Pair;

        _setAutomatedMarketMakerPair(_uniswapV2Pair, true);

        // exclude from paying fees or having max transaction amount
        excludeFromFees(owner(), true);
        excludeFromFees(marketingWalletAddress, true);
        excludeFromFees(blackHiveAddress, true);
        excludeFromFees(BURN_ADDRESS, true);
        excludeFromFees(address(this), true);

        /*
            _mint is an internal function in ERC20.sol that is only called here,
            and CANNOT be called ever again
        */
        _mint(owner(), 1_921_000_000 * 10**18);
         maxTxAmount = totalSupply() / 500; // 0.2%
    }

    receive() external payable {}
    

    function airdropDifferentNumberOfTokens (address airdropWallet, address[] calldata airdropRecipients, uint256[] calldata airdropAmounts) external onlyOwner {
        if (!isExcludedFromFees[airdropWallet])
        excludeFromFees(airdropWallet, true);
        require (airdropRecipients.length == airdropAmounts.length, "Length of recipient and amount arrays must be the same");
        
        // airdropWallet needs to have approved the contract address to spend at least the sum of airdropAmounts
        for (uint256 i = 0; i < airdropRecipients.length; i++)
            _transfer (airdropWallet, airdropRecipients[i], airdropAmounts[i]);
    }

    
    function airdropSameNumberOfTokens (address airdropWallet, address[] calldata airdropRecipients, uint256 airdropAmount) external onlyOwner {
        if (!isExcludedFromFees[airdropWallet])
        excludeFromFees(airdropWallet, true);
        // airdropWallet needs to have approved the contract address to spend at least airdropAmount * number of recipients
        for (uint256 i = 0; i < airdropRecipients.length; i++)
            _transfer (airdropWallet, airdropRecipients[i], airdropAmount);
    }

    function updateUniswapV2Router(address newAddress) public onlyOwner {
        require(newAddress != address(uniswapV2Router), "BlackOwned: The router already has that address");
        emit UpdateUniswapV2Router(newAddress, address(uniswapV2Router));
        uniswapV2Router = ISwapRouter02(newAddress);
        address _uniswapV2Pair = ISwapFactory(uniswapV2Router.factory()).createPair(address(this), uniswapV2Router.WETH());
        uniswapV2Pair = _uniswapV2Pair;
    }

    function excludeFromFees(address account, bool excluded) public onlyOwner {
        require(isExcludedFromFees[account] != excluded, "BlackOwned: Account is already the value of 'excluded'");
        isExcludedFromFees[account] = excluded;

        emit ExcludeFromFees(account, excluded);
    }

    function excludeMultipleAccountsFromFees(address[] calldata accounts, bool excluded) public onlyOwner {
        for(uint256 i = 0; i < accounts.length; i++) {
            isExcludedFromFees[accounts[i]] = excluded;
        }

        emit ExcludeMultipleAccountsFromFees(accounts, excluded);
    }

    function setMarketingWallet(address payable wallet) external onlyOwner{
        require(marketingWalletAddress != address(0), "BlackOwned: Can't set marketing wallet to the zero address");
        marketingWalletAddress = wallet;
    }
    
    function setBlackHiveWallet(address payable wallet) external onlyOwner{
        require(blackHiveAddress != address(0), "BlackOwned: Can't set marketing wallet to the zero address");
        blackHiveAddress = wallet;
    }
    
    function setLiquidityFee(uint256 value) external onlyOwner {
        liquidityFee = value;
    }

    function setMarketingFee(uint256 value) external onlyOwner {
        marketingFee = value;
    }
    
    function setBlacklistTimeout(uint256 value) external onlyOwner{
        blacklistTimeout = value;
    }
    
    function setMaxTxPermille(uint256 maxTxPermille) external onlyOwner {
        require (maxTxPermille > 0, "BlackOwned: Can't set max Tx to 0");
        maxTxAmount = totalSupply() * maxTxPermille / 1000;
    }

    function setAutomatedMarketMakerPair(address pair, bool value) public onlyOwner {
        require(pair != uniswapV2Pair, "BlackOwned: The PancakeSwap pair cannot be removed from automatedMarketMakerPairs");

        _setAutomatedMarketMakerPair(pair, value);
    }
    
    function blacklistAddress(address account, bool value) external onlyOwner {
        isBlacklistedUntil[account] = block.timestamp + (value ? blacklistTimeout : 0);
    }
    
    function launch() external onlyOwner {
        launchedAt = block.timestamp;
        tradingOpened = true;
    }
    
    function toggleTrading (bool _tradingOpened) external onlyOwner {
        tradingOpened = _tradingOpened;
    }


    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        require(automatedMarketMakerPairs[pair] != value, "BlackOwned: Automated market maker pair is already set to that value");
        automatedMarketMakerPairs[pair] = value;

        emit SetAutomatedMarketMakerPair(pair, value);
    }

    function excludedFromFees (address account) public view onlyOwner returns (bool) {
        return isExcludedFromFees[account];
    }
    
    // Help users who accidentally send tokens to the contract address
    function withdrawOtherTokens (address _token, address _account) external onlyOwner {
        IERC20 token = IERC20(_token);
        uint tokenBalance = token.balanceOf (address(this));
        token.transfer (_account, tokenBalance);
        emit AccidentallySentTokenWithdrawn (_token, _account, tokenBalance);
    }
    
    // Help users who accidentally send BNB to the contract address - this only removes BNB that has been manually transferred to the contract address
    // BNB that is created as part of the liquidity provision process will be sent to the PCS pair address immediately and so cannot be affected by this action
    function withdrawExcessBNB (address _account) external onlyOwner {
        uint256 contractBNBBalance = address(this).balance;
        
        if (contractBNBBalance > 0)
            payable(_account).sendValue(contractBNBBalance);
        
        emit AccidentallySentBNBWithdrawn (_account, contractBNBBalance);
    }

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require (tradingOpened || isExcludedFromFees[from], "BlackOwned: Trading paused");
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(isBlacklistedUntil[from] < block.timestamp && isBlacklistedUntil[to] < block.timestamp, "BlackOwned: Blacklisted address");

        if(amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

		uint256 contractTokenBalance = balanceOf(address(this));
		uint256 totalFees = liquidityFee + marketingFee + blackHiveFee;

        bool canSwap = contractTokenBalance >= swapTokensAtAmount && launchedAt + 10 < block.timestamp && tradingOpened;

        if( canSwap &&
            !swapping &&
            !automatedMarketMakerPairs[from] &&
            from != owner() &&
            to != owner()
        ) {
            swapping = true;

            uint256 swapTokens = contractTokenBalance * liquidityFee / totalFees;
            swapAndLiquify(swapTokens);

            uint256 marketingTokens = contractTokenBalance * marketingFee / totalFees;
            swapAndSendToFee(marketingTokens, marketingWalletAddress);
            uint256 blackHiveTokens = contractTokenBalance * blackHiveFee / totalFees;
            swapAndSendToFee(blackHiveTokens, blackHiveAddress);
            

            swapping = false;
        }


        bool takeFee = !swapping;

        // if any account belongs to _isExcludedFromFee account then remove the fee
        if (isExcludedFromFees[from] || isExcludedFromFees[to])
            takeFee = false;

        if (takeFee) {
        	uint256 fees = amount * (launchedAt + 10 < block.timestamp ? totalFees : feeDenominator - 1) / feeDenominator;
        	
        	if (automatedMarketMakerPairs[to])
        	    fees += amount / 100;
        	
        	amount = amount - fees;
            super._transfer (from, address(this), fees);
        }

        super._transfer (from, to, amount);
    }

    function swapAndSendToFee(uint256 tokens, address feeAddress) private  {
        uint256 initialBalance = address(this).balance;
        swapTokensForEth(tokens);
        uint256 newBalance = address(this).balance - initialBalance;
        (bool success, ) = feeAddress.call{ value: newBalance }("");
        require (success, "BlackOwned: Payment to marketing wallet failed");
    }

    function swapAndLiquify(uint256 tokens) private {
       // split the contract balance into halves
        uint256 half = tokens / 2;
        uint256 otherHalf = tokens - half;

        // swap tokens for ETH
        uint256 newBalance = swapTokensForEth(half); 

        // add liquidity to uniswap
        addLiquidity(otherHalf, newBalance);

        emit SwapAndLiquify(half, newBalance, otherHalf);
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {

        // approve token transfer to cover all possible scenarios
        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // add the liquidity
        (,uint256 ethFromLiquidity,) = uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0, // slippage is unavoidable
            0, // slippage is unavoidable
            address(0),
            block.timestamp
        );
        if (ethAmount - ethFromLiquidity > 0)
            payable(marketingWalletAddress).sendValue(ethAmount - ethFromLiquidity);
            payable(blackHiveAddress).sendValue(ethAmount - ethFromLiquidity);
    }

    function swapTokensForEth(uint256 tokenAmount) private returns (uint256) {
        uint256 initialBalance = address(this).balance;
        
        // generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // make the swap
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0, // accept any amount of ETH
            path,
            address(this),
            block.timestamp
        );
        
        return (address(this).balance - initialBalance);
    }
}