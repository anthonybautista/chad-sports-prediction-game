//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// OpenZeppelin
import "./openzeppelin/ReentrancyGuard.sol";
import "./openzeppelin/Ownable.sol";

// Chainlink Keepers
import "./chainlink-keepers/KeeperCompatibleInterface.sol";

// ERC721A
import "./chiru/ERC721A.sol";

interface IERC2981Royalties {
	function royaltyInfo(uint256 tokenID, uint256 value) external view returns(address receiver, uint256 royaltyAmount);
}

interface IOracle {
    function getResults() external returns(uint[] memory);
    function dataIsAvailable(uint8) external view returns(bool);
}

/// @title Chad Sports Prediction Game.
/// @author xrpant
/** @notice ERC721A flexible gamified prediction game contract for Chad Sports
* - This contract is designed to be used with a contract factory allowing anyone to create their own prediction game.
* - Chainlink Keepers compatible to automate opening and closing of rounds as well as point accumulation.
* - There is no maximum supply, however the minting will end 1 hour before the start of the first prediction round.
* - This contract requires a separate oracle contract to return results of the event being predicted. Results should be an array of point values where array index == option selected.
*/

contract ChadPredictionGame is ERC721A, Ownable, ReentrancyGuard, KeeperCompatibleInterface {

    constructor(address _owner,  
                address _royaltyAddress,
                address _oracle,
                uint256 _royaltyAmount,
                uint256 _price,
                uint256[][] memory _roundStartStop,
                uint8 _predictionsPerRound,
                uint8 _numRounds, 
                uint8 _numWinners,
                string memory _baseURI,
                string memory name, 
                string memory symbol) ERC721A(name, symbol) {
        
        royaltyAddress = _royaltyAddress;
        royaltyAmount = _royaltyAmount;

        price = _price;
        numWinners = _numWinners;

        currentRound = 1;
        predictionsPerRound = _predictionsPerRound;
        numRounds = _numRounds;
        require(_roundStartStop.length == numRounds, "Mismatch in numRounds and roundStartStop!");
        roundStartStop = _roundStartStop;

        baseURI = _baseURI;

        oracle = IOracle(_oracle);

        // this argument is mainly for when this is deployed by a factory.
        // at that point the if statement can be removed.
        if (_owner != msg.sender) {
            transferOwnership(_owner);
        }
    }
    
    /// @notice address where royalties will be sent 
    address public royaltyAddress; 

    /// @notice royalty percentage * 100 so that decimals can be used
    uint256 public royaltyAmount;

    /// @notice price to mint one NFT
    uint256 public price;

    /// @notice array of arrays, one pair of start/stop timestamps per round   
    uint256[][] public roundStartStop;

    /// @notice array of winners
    uint256[] public winners;

    /// @notice number of predictions that must be made per round
    uint8 public predictionsPerRound;

    /// @notice number of rounds
    uint8 public numRounds;

    /// @notice number of winners
    uint8 public numWinners;

    /// @notice current round
    uint8 public currentRound;

    /// @notice The URI Base for the metadata of the collection 
    string public baseURI;

    /// @notice oracle that will return results
    IOracle oracle;

    /// @notice mapping of tokenId -> round -> predictions
    mapping (uint256 => mapping (uint8 => uint256[])) public tokenToPredictions;

    /// @notice mapping of tokenId -> points
    mapping (uint256 => uint256) public tokenToPoints;

    /// @notice struct for predictions that will be stored in an array for easy access;
    struct Prediction {
        uint256 tokenId; 
        uint256[] predictions;
    }

    mapping (uint8 => Prediction[]) public roundToPredictions;


    // E V E N T S

    /// @notice Emitted from mint()
    /// @param amount The amount of received AVAX
    event ReceivedAvax(uint amount);

    /// @notice Emitted on withdrawBalance() 
    event BalanceWithdraw(address to, uint amount);

    /// @notice Emitted on makePredictions() 
    event PredictionMade(uint256 tokenId, uint8 round, uint256[] predictions);

    /// @notice Emitted on performUpkeep() 
    event PointsEarned(uint8 round, uint256 tokenId, uint256 points);

    /// @notice Emitted on performUpkeep() 
    event ResultsObtained(uint8 round, uint256[] points);
    
    // Mint 
    function mint(uint256 amount) public payable nonReentrant {
        // stop minting 1 hour before first round ends
        require(block.timestamp + 1 hours < roundStartStop[0][1], "Minting has ended!");
        require(msg.value == amount * price, "Insufficient funds!");
        _mint(msg.sender, amount); 

        emit ReceivedAvax(msg.value);
    }

    /**
    * @notice Function to make predictions
    * @dev must make selections equal to predictionsPerRound and predictions close 5 minutes before 
    * round start.
    */
    function makePredictions(uint256 tokenId, uint256[] calldata predictions) public nonReentrant {
        require(ownerOf(tokenId) == msg.sender, "You don't own that token!");
        require(block.timestamp >= roundStartStop[currentRound - 1][0], "Predictions for this round hasn't started!");
        require(block.timestamp + 5 minutes < roundStartStop[currentRound - 1][1], "Predictions for this round closed!");
        require(predictions.length == predictionsPerRound, "Invalid number of predictions");

        tokenToPredictions[tokenId][currentRound] = predictions;

        Prediction memory p;
        p.tokenId = tokenId;
        p.predictions = predictions;

        roundToPredictions[currentRound - 1].push(p);

        emit PredictionMade(tokenId, currentRound - 1, predictions);
    }

    function getPredictionsForRound(uint8 round) external view returns(Prediction[] memory) {
        return roundToPredictions[round];
    }

    function getPointsForPlayers() external view returns(uint256[] memory) {
        uint256[] memory _points = new uint256[](totalSupply());
        for (uint256 i = 0; i < totalSupply(); i++) {
            _points[i] = (tokenToPoints[i]);
        }

        return _points;
    }

    // Keepers Functions
    function checkUpkeep(
        bytes calldata /* checkData */
    ) external view override returns (bool upkeepNeeded, bytes memory performData) {
        upkeepNeeded = false;

        // trigger upkeep if current round is over
        if (block.timestamp > roundStartStop[currentRound - 1][1] &&
            currentRound <= numRounds && 
            oracle.dataIsAvailable(currentRound)) {
            upkeepNeeded = true;
        }

        return (upkeepNeeded, "");
    }

    function performUpkeep(
        bytes calldata /* performData */
    ) external override {
        require(block.timestamp > roundStartStop[currentRound - 1][1] &&
            currentRound <= numRounds && 
            oracle.dataIsAvailable(currentRound), "Results not available");

        uint256[] memory results = oracle.getResults();

        emit ResultsObtained(currentRound, results);

        Prediction[] memory _predictions = roundToPredictions[currentRound - 1];

        for (uint256 i = 0; i < _predictions.length; i++) {
            Prediction memory p = _predictions[i];
            uint256 points = 0;
            for (uint j = 0; j < p.predictions.length; j++) {
                if (p.predictions[j] < results.length &&
                    p.predictions[j] >= 0) {
                    points += results[p.predictions[j]];
                }
            }

            if (points > 0) {
                tokenToPoints[p.tokenId] += points;

                emit PointsEarned(currentRound, p.tokenId, points);
            }
            
        }    

        currentRound += 1;
    }

    /// @notice Withdraw the contract balance to the contract owner
    /// @param _to Recipient of the withdrawal
    function withdrawBalance(address _to) external onlyOwner {
        uint amount = address(this).balance;

        (bool sent, ) = _to.call{value: amount}("");
        require(sent, "Error transferring funds!");

        emit BalanceWithdraw(_to, amount);
    }

    /// @notice manually set winning tokenIds for now. look to automate later
    function setWinners(uint256[] calldata _winners) public onlyOwner {
        require(currentRound > numRounds, "Game hasn't finished!");
        require(_winners.length == numWinners, "Incorrect number of winners!");

        winners = _winners;
    }

    /// @notice manually pay winners for now. look to automate later
    function payWinners() public onlyOwner {
        require(currentRound > numRounds, "Game hasn't finished!");
        require(winners.length > 0, "Winners not set!");

        uint256 prize = address(this).balance / numWinners;

        for (uint256 i = 0; i < numWinners; i++) {
            (bool sent, ) = ownerOf(winners[i]).call{value: prize}("");
            require(sent, "Error transferring funds!");
        }
    }

    // R O Y A L T I E S

    /// @dev Royalties implementation.

    /**
     * @dev EIP2981 royalties implementation: set the recepient of the royalties fee to 'newRecepient'
     * Maintain flexibility to modify royalties recipient (could also add basis points).
     *
     * Requirements:
     *
     * - `newRecepient` cannot be the zero address.
     */

    function setRoyalties(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), "Royalties cannot go to 0 Address");
        royaltyAddress = newRecipient;
    }

    // EIP2981 standard royalties return.
    function royaltyInfo(uint256, uint256 value) external view returns(address, uint256) {
        return (royaltyAddress , value * royaltyAmount / 10000);
    } 

    function supportsInterface(bytes4 interfaceID) public view override (ERC721A) returns(bool) {
        return interfaceID == type(IERC2981Royalties).interfaceId || super.supportsInterface(interfaceID);
    }

    // Oracle Functions
    function setOracle(address _newOracle) external onlyOwner {
        oracle = IOracle(_newOracle);
    }

    // URI Functions
    function updateBaseURI(string calldata _newURI) external onlyOwner {
        baseURI = _newURI;
    }

    function tokenURI(uint256 tokenId) public view virtual override (ERC721A) returns (string memory) {
        if (!_exists(tokenId)) revert URIQueryForNonexistentToken();
        
        return bytes(baseURI).length != 0 ? string(abi.encodePacked(baseURI)) : "";
    }

    // start at token #1
    function _startTokenId() internal view virtual override returns (uint256) {
        return 1;
    }
    
}