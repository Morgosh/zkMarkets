//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.23;
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./ERC721A.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

interface IWETH {
    function deposit() external payable;
    function transfer(address dst, uint wad) external returns (bool);
}

contract ERC721Template is IERC2981, Ownable, ERC721A  {
    using Strings for uint256;
    using SafeERC20 for IERC20;

    string private baseURI;
    string public notRevealedURI;
    uint256 public maxSupply;
    uint256 public publicPrice;
    uint256 public publicMaxMintAmount;
    uint256 public publicSaleStartTime = type(uint256).max;
    bool public isRevealed;

    address payable public immutable withdrawalRecipientAddress; // address that will receive revenue
    address payable public immutable comissionRecipientAddress;// address that will receive a part of revenue on withdrawal
    uint256 public immutable comissionPercentageIn10000; // percentage of revenue to be sent to comissionRecipientAddress
    uint256 private immutable fixedCommissionTreshold;
    uint256 private totalComissionWithdrawn;

    string public contractURI;
    //presale price is set after

    // Default royalty info
    address payable public defaultRoyaltyRecipient;
    uint256 public defaultRoyaltyPercentageIn10000;

    // Add new state variables to handle ERC20 payments
    address public ERC20TokenAddress;
    uint256 public ERC20FixedPricePerToken; // Fixed price per token in ERC20
    uint256 public ERC20DiscountIn10000; // Discount percentage for ERC20 payments
    
    address public ERC20PriceFeedAddress;
    address public ethPriceFeedAddress;

    // Per-token royalty info
    mapping(uint256 => address payable) public tokenRoyaltyRecipient;
    mapping(uint256 => uint256) public tokenRoyaltyPercentage;

    event ContractURIUpdated();
    bool public tradingEnabled = true;
    mapping(address => bool) public blacklist;

    IWETH constant private WETH = IWETH(0x5AEa5775959fBC2557Cc8789bC1bf90A239D9a91);

    // todo check burnable adition
    constructor(
        string memory _name,
        string memory _symbol,
        string memory _contractURI,
        uint256 _maxSupply,
        uint256 _publicPrice,
        string memory _defaultBaseURI,
        string memory _notRevealedURI,
        address payable _withdrawalRecipientAddress,
        address payable _comissionRecipientAddress,
        uint256 _fixedCommisionTreshold,
        uint256 _comissionPercentageIn10000,
        address payable _defaultRoyaltyRecipient, // separate from withdrawal recipient to enhance security
        uint256 _defaultRoyaltyPercentageIn10000
        // set max mint amount after deployment
    ) ERC721A(_name, _symbol) Ownable(msg.sender) {
        maxSupply = _maxSupply;
        publicPrice = _publicPrice;
        contractURI = _contractURI; // no need to emit event here, as it's set in the constructor
        baseURI = _defaultBaseURI;
        notRevealedURI =_notRevealedURI;
        publicMaxMintAmount = 10000;
        withdrawalRecipientAddress = _withdrawalRecipientAddress;
        comissionRecipientAddress = _comissionRecipientAddress;
        fixedCommissionTreshold = _fixedCommisionTreshold;
        // Ensure commission percentage is between 0 and 10000 (0-100%)
        require(_comissionPercentageIn10000 <= 10000, "Invalid commission percentage");
        comissionPercentageIn10000 = _comissionPercentageIn10000;
        defaultRoyaltyRecipient = _defaultRoyaltyRecipient;
        defaultRoyaltyPercentageIn10000 = _defaultRoyaltyPercentageIn10000;
        isRevealed = bytes(_notRevealedURI).length == 0;
    }

    function _beforeTokenTransfers(
        address from,
        address to,
        uint256 tokenId,
        uint256 batchSize
    )
        internal override
    {
        if (from != address(0)) {
            require(tradingEnabled, "Trading is disabled");
            require(!blacklist[msg.sender], "Blacklisted entities cannot execute trades");
        }
        super._beforeTokenTransfers(from, to, tokenId, batchSize);
    }
    
    function tokenURI(
        uint256 tokenId
    ) public view virtual override returns (string memory) {
        require(
            ownerOf(tokenId) != address(0),
            "ERC721Metadata: URI query for nonexistent token"
        );
        if (isRevealed == false) {
            return notRevealedURI;
        }
        string memory identifier = tokenId.toString();
        return
            bytes(baseURI).length != 0
                ? string(abi.encodePacked(baseURI, identifier, ".json"))
                : "";
    }

    function getPublicMintEligibility() public view returns (uint256) {
        uint256 balance = balanceOf(msg.sender);
        uint256 maxMint = publicMaxMintAmount;
        if (balance >= maxMint) {
            return 0;
        }
        return maxMint - balance;
    }

    function getLaunchpadDetails() external view returns (uint256, uint256, uint256, uint256) {
        return (maxSupply, publicPrice, totalSupply(), publicSaleStartTime);
    }

    function getLaunchpadDetailsERC20() external view returns (address, uint256, uint256) {
        uint256 requiredTokens = 0;
        if (ethPriceFeedAddress != address(0) && ERC20PriceFeedAddress != address(0)) {
            requiredTokens = getRequiredERC20TokensChainlink(publicPrice);
        }

        return (ERC20TokenAddress, ERC20FixedPricePerToken, requiredTokens);
    }

    function checkMintRequirements(uint256 _mintAmount) internal view {
        require(totalSupply() + _mintAmount <= maxSupply, "Total supply exceeded");
        require(block.timestamp >= publicSaleStartTime, "Public sale not active");
        require(getPublicMintEligibility() >= _mintAmount, "Invalid amount to be minted");
        require(balanceOf(msg.sender) + _mintAmount <= publicMaxMintAmount, "Invalid amount to be minted");
    }

    function mint(uint256 _mintAmount) external payable {
        checkMintRequirements(_mintAmount);
        require(msg.value >= publicPrice * _mintAmount, "Cost is higher than the amount sent");
        _safeMint(msg.sender, _mintAmount);
    }

    function getLatestPrice(address priceFeedAddress) internal view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeedAddress);
        (, int256 price,,,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price from Chainlink");
        return uint256(price);
    }

    function getRequiredERC20TokensChainlink(uint256 ethPrice) public view returns (uint256) {
        address ethPriceFeed = ethPriceFeedAddress;
        address ERC20PriceFeed = ERC20PriceFeedAddress;
        require(ethPriceFeed != address(0) && ERC20PriceFeed != address(0), "Price feed addresses not set");

        // Get the latest prices from Chainlink
        uint256 ethPriceInUsd = getLatestPrice(ethPriceFeed);
        uint256 ERC20PriceInUsd = getLatestPrice(ERC20PriceFeed);

        // Prices from Chainlink are usually returned with 8 decimals
        uint256 ethPriceInUsdScaled = ethPriceInUsd * 10**10; // Scale to 18 decimals
        uint256 ERC20PriceInUsdScaled = ERC20PriceInUsd * 10**10; // Scale to 18 decimals

        // Calculate the equivalent cost in ERC20 tokens
        uint256 totalERC20Cost = (ethPrice * ethPriceInUsdScaled) / ERC20PriceInUsdScaled;

        // Apply discount if set
        uint256 ERC20Discount = ERC20DiscountIn10000;
        if (ERC20Discount > 0) {
            totalERC20Cost = (totalERC20Cost * (10000 - ERC20Discount)) / 10000;
        }

        return totalERC20Cost;
    }

    function mintWithERC20ChainlinkPrice(uint256 _mintAmount) external {
        checkMintRequirements(_mintAmount);
        // Let's make sure price feed contract address exists
        address ERC20Token = ERC20TokenAddress;
        require(ERC20Token != address(0), "Payment token address not set");

        // Calculate the cost in ERC20 tokens
        uint256 requiredTokenAmount = getRequiredERC20TokensChainlink(publicPrice * _mintAmount);

        IERC20(ERC20Token).safeTransferFrom(msg.sender, address(this), requiredTokenAmount);

        _safeMint(msg.sender, _mintAmount);
    }

    function mintWithFixedERC20Price(uint256 _mintAmount) external {
        checkMintRequirements(_mintAmount);
        address ERC20Token = ERC20TokenAddress;
        uint256 ERC20FixedPrice = ERC20FixedPricePerToken;
        require(ERC20Token != address(0), "Payment token address not set");
        require(ERC20FixedPrice > 0, "Price per token not set");

        // Calculate the cost in ERC20 tokens
        uint256 requiredTokenAmount = ERC20FixedPrice * _mintAmount;

        IERC20(ERC20Token).safeTransferFrom(msg.sender, address(this), requiredTokenAmount);

        _safeMint(msg.sender, _mintAmount);
    }

    function adminMint(address _to, uint256 _mintAmount) public onlyOwner {
        require(totalSupply() + _mintAmount <= maxSupply, "Total supply exceeded");
        _safeMint(_to, _mintAmount);
    }

    function batchAdminMint(address[] calldata recipients, uint256[] calldata amounts) external onlyOwner {
        for (uint256 i = 0; i < recipients.length; i++) {
            adminMint(recipients[i], amounts[i]);
        }
    }

    function setPublicPrice(uint256 _newPrice) external onlyOwner {
        publicPrice = _newPrice;
    }

    function setBaseURI(string memory _newBaseURI) external onlyOwner {
        baseURI = _newBaseURI;
    }

    function setNotRevealedURI(string memory _notRevealedURI) external onlyOwner {
        notRevealedURI = _notRevealedURI;
    }

    function setMaxSupply(uint256 _newmaxSupply) external onlyOwner {
        maxSupply = _newmaxSupply;
    }

    function togglePublicSaleActive() external onlyOwner {
        if (block.timestamp < publicSaleStartTime) {
            publicSaleStartTime = block.timestamp;
        } else {
            // This effectively disables the public sale by setting the start time to a far future
            publicSaleStartTime = type(uint256).max;
        }
    }

    // Sets the start time of the public sale to a specific timestamp
    function setPublicSaleStartTime(uint256 _publicSaleStartTime) external onlyOwner {
        publicSaleStartTime = _publicSaleStartTime;
    }

    function setPublicMaxMintAmount(uint256 _publicMaxMintAmount) external onlyOwner {
        publicMaxMintAmount = _publicMaxMintAmount;
    }

    function toggleReveal() external onlyOwner {
        isRevealed = !isRevealed;
    }

    function setDefaultRoyaltyInfo(address payable _defaultRoyaltyRecipient, uint256 _defaultRoyaltyPercentageIn10000) external onlyOwner {
        defaultRoyaltyRecipient = _defaultRoyaltyRecipient;
        defaultRoyaltyPercentageIn10000 = _defaultRoyaltyPercentageIn10000;
    }

    function setTokenRoyaltyInfo(uint256 _tokenId, address payable _royaltyRecipient, uint256 _royaltyPercentage) external onlyOwner {
        require(ownerOf(_tokenId) != address(0), "Token does not exist");
        tokenRoyaltyRecipient[_tokenId] = _royaltyRecipient;
        tokenRoyaltyPercentage[_tokenId] = _royaltyPercentage;
    }
    
    function setContractURI(string memory newURI) external onlyOwner {
        contractURI = newURI;
        emit ContractURIUpdated();
    }

    function setERC20TokenAddress(address _ERC20TokenAddress) external onlyOwner {
        ERC20TokenAddress = _ERC20TokenAddress;
    }

    function setErc20FixedPricePerToken(uint256 _erc20FixedPricePerToken) external onlyOwner {
        ERC20FixedPricePerToken = _erc20FixedPricePerToken;
    }

    function setERC20PriceFeedAddress(address _ERC20PriceFeedAddress) external onlyOwner {
        ERC20PriceFeedAddress = _ERC20PriceFeedAddress;
    }

    function setETHPriceFeedAddress(address _ethPriceFeedAddress) external onlyOwner {
        ethPriceFeedAddress = _ethPriceFeedAddress;
    }

    function setERC20DiscountIn10000(uint256 _erc20DiscountIn10000) external onlyOwner {
        require(_erc20DiscountIn10000 <= 10000, "Invalid discount percentage");
        ERC20DiscountIn10000 = _erc20DiscountIn10000;
    }

    // implement ERC2981
    function royaltyInfo(uint256 _tokenId, uint256 _salePrice) external view override returns (address, uint256) {
        uint256 royaltyPercentage = tokenRoyaltyPercentage[_tokenId] != 0 ? tokenRoyaltyPercentage[_tokenId] : defaultRoyaltyPercentageIn10000;
        address royaltyRecipient = tokenRoyaltyRecipient[_tokenId] != address(0) ? tokenRoyaltyRecipient[_tokenId] : defaultRoyaltyRecipient;
        return (royaltyRecipient, (_salePrice * royaltyPercentage) / 10000);
    }

    function withdrawFixedComission() external {
        require(
            msg.sender == owner() || msg.sender == comissionRecipientAddress,
            "Only owner or commission recipient can withdraw"
        );
        uint256 withdrawn = totalComissionWithdrawn;
        uint256 remainingCommission = fixedCommissionTreshold - withdrawn;
        uint256 amount = remainingCommission > address(this).balance 
                        ? address(this).balance 
                        : remainingCommission;

        // Ensure we don't exceed the fixed commission threshold
        require(withdrawn + amount <= fixedCommissionTreshold, "Total withdrawal by commission cannot exceed the threshold");

        // Updating the total withdrawn by A before making the transfer
        totalComissionWithdrawn += amount;
        (bool success, ) = comissionRecipientAddress.call{value: amount}("");
        require(success, "Transfer failed");
    }

    function withdraw() external virtual {
        require(
            msg.sender == owner() || msg.sender == comissionRecipientAddress  || msg.sender == withdrawalRecipientAddress,
            "Only owner or commission recipient can withdraw"
        );

        uint256 available = address(this).balance - (fixedCommissionTreshold - totalComissionWithdrawn);

        uint256 comission = (available * comissionPercentageIn10000) /
            10000; // Divide by 10000 instead of 100
        uint256 ownerAmount = available - comission;

        if (comission > 0) {
            (bool cs, ) = comissionRecipientAddress.call{value: comission}("");
            if (!cs) {
                WETH.deposit{value: comission}();
                IERC20(address(WETH)).safeTransfer(comissionRecipientAddress, comission);
            }
        }

        if (ownerAmount > 0) {
            (bool os, ) = withdrawalRecipientAddress.call{value: ownerAmount}("");
            if (!os) {
                WETH.deposit{value: ownerAmount}();
                IERC20(address(WETH)).safeTransfer(withdrawalRecipientAddress, ownerAmount);
            }
        }
    }

    function withdrawERC20(IERC20 erc20Token) external {
        require(
            msg.sender == owner() || msg.sender == comissionRecipientAddress  || msg.sender == withdrawalRecipientAddress,
            "Only owner or commission recipient can withdraw"
        );
        uint256 erc20Balance = erc20Token.balanceOf(address(this));
        uint256 comission = (erc20Balance * comissionPercentageIn10000) / 10000;
        uint256 withdrawalAddressAmount = erc20Balance - comission;

        //withdrawalRecipientAddress
        if(comission > 0) {
            erc20Token.safeTransfer(comissionRecipientAddress, comission);
        }

        if(withdrawalAddressAmount > 0) {
            erc20Token.safeTransfer(withdrawalRecipientAddress, withdrawalAddressAmount);
        }
    }

    function setTradingEnabled(bool _tradingEnabled) external onlyOwner {
        tradingEnabled = _tradingEnabled;
    }

    function addToBlacklist(address _address) external onlyOwner {
        blacklist[_address] = true;
    }

    function removeFromBlacklist(address _address) external onlyOwner {
        blacklist[_address] = false;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721A, IERC165) returns (bool) {
        return interfaceId == type(IERC2981).interfaceId || 
            ERC721A.supportsInterface(interfaceId) || 
            super.supportsInterface(interfaceId);
    }

    // Override _startTokenId if you want your token IDs to start from 1 instead of 0
    function _startTokenId() internal view virtual override returns (uint256) {
        return 1;
    }
}