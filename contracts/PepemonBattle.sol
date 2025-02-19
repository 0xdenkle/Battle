// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;
import "./lib/AdminRole.sol";
import "./PepemonCardDeck.sol";
import "./PepemonCardOracle.sol";
import "./lib/ChainLinkRngOracle.sol";

contract PepemonBattle is AdminRole {
    
    event BattleCreated(uint256 battleId, address player1Addr, address player2Addr);

    mapping (uint => uint) public battleIdRNGSeed;

    uint constant _max_inte = 8;
    uint constant _max_cards_on_table = 5;
    uint constant _refreshTurn = 5;

    //Attacker can either be PLAYER_ONE or PLAYER_TWO
    enum Attacker {
        PLAYER_ONE,
        PLAYER_TWO
    }

    //Game can either be in FIRST_HALF or SECOND_HALF
    enum TurnHalves {
        FIRST_HALF,
        SECOND_HALF
    }

    //Battle contains:
    //battleId = ID of this battle
    //player1, player2 = players
    //currentTurn
    //attacker
    //turnHalves => first half or second half?
    struct Battle {
        uint256 battleId;
        Player player1;
        Player player2;
        uint256 currentTurn;
        Attacker attacker;
        TurnHalves turnHalves;
    }

    //playerAddr
    //deckId = Id of deck
    //hand = keeps track of current player's stats (such as health)
    //totalSupportCardIds = all IDs of support cards
    //playedCardCount = number of cards played already
    struct Player {
        address playerAddr;
        uint256 deckId;
        Hand hand;
        uint256[60] totalSupportCardIds;
        uint256 playedCardCount;
    }

    //health - health of player's battle card
    // battleCardId = card id of player
    // currentBCstats = all stats of the player's battle cards currently
    // supportCardInHandIds = IDs of the support cards in your current hand
    //                  the amount of support cards a player can play is determined by intelligence
    // tableSupportCardStats = Number of support cards that are currently played on the table
    // currentSuportCards = cards on the table, based on which turn ago they were played
    //                      Notice that the number of turns is limited by _refreshTurn
    struct Hand {
        int256 health;
        uint256 battleCardId;
        CurrentBattleCardStats currentBCstats;
        uint256[_max_inte] supportCardInHandIds;
        uint256 tableSupportCardStats;
        TableSupportCardStats[_max_cards_on_table] tableSupportCards;
    }
    //spd, inte, def, atk, sAtk, sDef - Current stats of battle card (with powerups included)
    //Each param can go into the negatives
    struct CurrentBattleCardStats {
        int256 spd;
        uint256 inte;
        int256 def;
        int256 atk;
        int256 sAtk;
        int256 sDef;
    }

    //links supportCardID with effectMany
    struct TableSupportCardStats {
        uint256 supportCardId;
        PepemonCardOracle.EffectMany effectMany;
    }

    mapping(uint256 => Battle) public battles;

    uint256 private _nextBattleId;


    PepemonCardOracle private _cardContract;
    PepemonCardDeck private _deckContract;
    ChainLinkRngOracle private _randNrGenContract;

    constructor(
        address cardOracleAddress,
        address deckOracleAddress,
        address randOracleAddress
    ) {
        _cardContract = PepemonCardOracle(cardOracleAddress);
        _deckContract = PepemonCardDeck(deckOracleAddress);
        _randNrGenContract = ChainLinkRngOracle(randOracleAddress);
        _nextBattleId = 1;
    }

    /**
     * @dev Create battle
     * @param p1Addr address player1
     * @param p1DeckId uint256
     * @param p2Addr address player2
     * @param p2DeckId uint256
     */
    function createBattle(
        address p1Addr,
        uint256 p1DeckId,
        address p2Addr,
        uint256 p2DeckId
    ) public onlyAdmin {
        require(p1Addr != p2Addr, "PepemonBattle: Cannot battle yourself");

        (uint256 p1BattleCardId, ) = _deckContract.decks(p1DeckId);
        (uint256 p2BattleCardId, ) = _deckContract.decks(p2DeckId);

        PepemonCardOracle.BattleCardStats memory p1BattleCard = _cardContract.getBattleCardById(p1BattleCardId);
        PepemonCardOracle.BattleCardStats memory p2BattleCard = _cardContract.getBattleCardById(p2BattleCardId);

        Battle storage newBattle;
        // Initiate battle ID
        newBattle.battleId = _nextBattleId;
        // Initiate player1
        newBattle.player1.hand.health = int256(p1BattleCard.hp);
        newBattle.player1.hand.battleCardId = p1BattleCardId;
        newBattle.player1.playerAddr = p1Addr;
        newBattle.player1.deckId = p1DeckId;
        // Initiate player2
        newBattle.player2.hand.health = int256(p2BattleCard.hp);
        newBattle.player2.hand.battleCardId = p2BattleCardId;
        newBattle.player2.playerAddr = p2Addr;
        newBattle.player2.deckId = p2DeckId;
        // Set the RNG seed
        battleIdRNGSeed[_nextBattleId] = _randSeed(newBattle);

        //Write battle into mapping
        battles[_nextBattleId] = newBattle;
        //Emit event
        emit BattleCreated(_nextBattleId, p1Addr, p2Addr);
        _nextBattleId++;
    }

    function goForBattle(Battle memory battle) public view returns (Battle memory, address winner) {

        //Initialize battle by starting the first turn
        battle = goForNewTurn(battle);
        address winnerAddr;
        // Battle goes!
        while (true) {
            // Resolve attacker in the current turn
            battle = resolveAttacker(battle);
            // Fight
            battle = fight(battle);

            // Check if battle ended
            (bool isEnded, address win) = checkIfBattleEnded(battle);
            if (isEnded) {
                winnerAddr = win;
                break;
            }

            // Resolve turn halves
            battle = updateTurnInfo(battle);
        }
        return (battle, winnerAddr);
    }

    //If currently in first half -> go to second half
    //If currently in second half -> make a new turn
    function updateTurnInfo(Battle memory battle) internal view returns (Battle memory) {
        // If the current half is first, go over second half
        // or go over next turn
        if (battle.turnHalves == TurnHalves.FIRST_HALF) {
            battle.turnHalves = TurnHalves.SECOND_HALF;
        } else {
            battle = goForNewTurn(battle);
        }

        return battle;
    }

    //Things this function does:
    //Reset both players hand infos back to base stats (stats with no support card powerups)
    //Check if support cards need to be scrambled and redealt
    //Redeal support cards if necessary
    //Calculate support card's power
    //Finally, draw Pepemon's intelligence number of cards.
    function goForNewTurn(Battle memory battle) internal view returns (Battle memory) {
        Player memory player1 = battle.player1;
        Player memory player2 = battle.player2;

        // Get base battle card stats (stats without any powerups)
        PepemonCardOracle.BattleCardStats memory p1BattleCard = _cardContract.getBattleCardById(
            player1.hand.battleCardId
        );
        PepemonCardOracle.BattleCardStats memory p2BattleCard = _cardContract.getBattleCardById(
            player2.hand.battleCardId
        );

        //Reset both players' hand infos to base stats
        player1.hand.currentBCstats = getCardStats(p1BattleCard);
        player2.hand.currentBCstats = getCardStats(p2BattleCard);

        //Refresh cards every 5 turns
        bool isRefreshTurn = (battle.currentTurn % _refreshTurn == 0);

        if (isRefreshTurn) {
            //Need to refresh decks

            // Shuffle player1 support cards
            uint256 p1SupportCardIdsLength = _deckContract.getSupportCardCountInDeck(player1.deckId);

            //Create a pseudorandom seed and shuffle the cards 
            uint[] memory scrambled = _deckContract.shuffleDeck(player1.deckId, 
                _randMod(
                    69, battle
                )
            );
            //Copy back scrambled cards to original list
            for (uint i = 0 ; i < p1SupportCardIdsLength; i++){
                player1.totalSupportCardIds[i]=scrambled[i];
            }
            
            //Reset played card count
            player1.playedCardCount = 0;

            //Shuffling player 2 support cards
            uint256 p2SupportCardIdsLength = _deckContract.getSupportCardCountInDeck(player2.deckId);

            //Create a pseudorandom seed and shuffle the cards
            uint[] memory scrambled2 = _deckContract.shuffleDeck(player2.deckId, 
                _randMod(
                    420, battle
                )
            );

            //Copy the support cards back into the list
            for (uint256 i = 0; i < p2SupportCardIdsLength; i++) {
                player1.totalSupportCardIds[i]=scrambled2[i];
            }
            
            //Reset player2 played card counts
            player2.playedCardCount = 0;
        }
        else 
        {
            //Don't need to refresh cards now

            // Get temp support info of previous turn's hands and calculate their effect for the new turn
            player1.hand = calSupportCardsOnTable(player1.hand, player2.hand);
            player2.hand = calSupportCardsOnTable(player2.hand, player1.hand);
        }

        // Draw player1 support cards for the new turn
        for (uint256 i = 0; i < player1.hand.currentBCstats.inte; i++) {
            player1.hand.supportCardInHandIds[i] = player1.totalSupportCardIds[i + player1.playedCardCount];
        }
        player1.playedCardCount += player1.hand.currentBCstats.inte;

        // Draw player2 support cards for the new turn
        for (uint256 i = 0; i < player2.hand.currentBCstats.inte; i++) {
            player2.hand.supportCardInHandIds[i] = player2.totalSupportCardIds[i + player2.playedCardCount];
        }
        player2.playedCardCount += player2.hand.currentBCstats.inte;

        //Update current battle info
        battle.player1 = player1;
        battle.player2 = player2;

        // Increment current turn number of battle
        battle.currentTurn++;

        // Go for first half in turn
        battle.turnHalves = TurnHalves.FIRST_HALF;

        return battle;
    }

    //This method calculates the battle card's stats after taking into consideration all the support cards currently being played
    function calSupportCardsOnTable(Hand memory hand, Hand memory oppHand) internal pure returns (Hand memory) {
        for (uint256 i = 0; i < hand.tableSupportCardStats; i++) {
            //Loop through every support card currently played

            //Get the support card being considered now
            TableSupportCardStats memory tableSupportCardStat = hand.tableSupportCards[i];
            
            //Get the effect of that support card
            PepemonCardOracle.EffectMany memory effect = tableSupportCardStat.effectMany;
            
            //If there is at least 1 turn left
            if (effect.numTurns >= 1) {

                //If the effect is for me
                if (effect.effectFor == PepemonCardOracle.EffectFor.ME) {
                    // Change my card's stats using that support card
                    // Currently effectTo of EffectMany can be ATTACK, DEFENSE, SPEED and INTELLIGENCE
                    //Get the statistic changed and update it 
                    //Intelligence can't go into the negatives
                    if (effect.effectTo == PepemonCardOracle.EffectTo.ATTACK) {
                        hand.currentBCstats.atk += effect.power;
                    } else if (effect.effectTo == PepemonCardOracle.EffectTo.DEFENSE) {
                        hand.currentBCstats.def += effect.power;
                    } else if (effect.effectTo == PepemonCardOracle.EffectTo.SPEED) {
                        hand.currentBCstats.spd += effect.power;
                    } else if (effect.effectTo == PepemonCardOracle.EffectTo.INTELLIGENCE) {
                        int temp;
                        temp = int256(hand.currentBCstats.inte) + effect.power;
                        hand.currentBCstats.inte = (temp > 0 ? uint(temp) : 0);
                    }
                } else {
                    //The card affects the opp's pepemon
                    //Update card stats of the opp's pepemon
                    //Make sure INT stat can't go below zero
                    if (effect.effectTo == PepemonCardOracle.EffectTo.ATTACK) {
                        oppHand.currentBCstats.atk += effect.power;
                    } else if (effect.effectTo == PepemonCardOracle.EffectTo.DEFENSE) {
                        oppHand.currentBCstats.def += effect.power;
                    } else if (effect.effectTo == PepemonCardOracle.EffectTo.SPEED) {
                        oppHand.currentBCstats.spd += effect.power;
                    } else if (effect.effectTo == PepemonCardOracle.EffectTo.INTELLIGENCE) {
                        int temp;
                        temp = int256(oppHand.currentBCstats.inte) + effect.power;
                        oppHand.currentBCstats.inte = (temp > 0 ? uint(temp) : 0);
                    }
                }
                // Decrease effect numTurns by 1 since 1 turn has already passed
                effect.numTurns--;
                // Delete this one from tableSupportCardStat if all turns of the card have been exhausted
                if (effect.numTurns == 0) {
                    if (i < hand.tableSupportCardStats - 1) {
                        hand.tableSupportCards[i] = hand.tableSupportCards[hand.tableSupportCardStats - 1];
                    }
                    delete hand.tableSupportCards[hand.tableSupportCardStats - 1];
                    hand.tableSupportCardStats--;
                }
            }
        }

        return hand;
    }

    //This method gets the current attacker
    function resolveAttacker(Battle memory battle) internal view returns (Battle memory) {
        CurrentBattleCardStats memory p1CurrentBattleCardStats = battle.player1.hand.currentBCstats;
        CurrentBattleCardStats memory p2CurrentBattleCardStats = battle.player2.hand.currentBCstats;

        if (battle.turnHalves == TurnHalves.FIRST_HALF) {
            //Player with highest speed card goes first
            if (p1CurrentBattleCardStats.spd > p2CurrentBattleCardStats.spd) {
                battle.attacker = Attacker.PLAYER_ONE;
            } else if (p1CurrentBattleCardStats.spd < p2CurrentBattleCardStats.spd) {
                battle.attacker = Attacker.PLAYER_TWO;
            } else {
                //Tiebreak: intelligence
                if (p1CurrentBattleCardStats.inte > p2CurrentBattleCardStats.inte) {
                    battle.attacker = Attacker.PLAYER_ONE;
                } else if (p1CurrentBattleCardStats.inte < p2CurrentBattleCardStats.inte) {
                    battle.attacker = Attacker.PLAYER_TWO;
                } else {
                    //Second tiebreak: use RNG
                    uint256 rand = _randMod(69420, battle) % 2;
                    battle.attacker = (rand == 0 ? Attacker.PLAYER_ONE : Attacker.PLAYER_TWO);
                }
            }
        } else {
            //For second half, switch players
            battle.attacker = (battle.attacker == Attacker.PLAYER_ONE ? Attacker.PLAYER_TWO : Attacker.PLAYER_ONE);
        }

        return battle;
    }

    //Create a random seed, using the chainlink number and the addresses of the combatants as entropy
    function _randSeed(Battle memory battle) private view returns (uint256) {
        //Get the chainlink random number
        uint chainlinkNumber = _randNrGenContract.getRandomNumber();
        //Create a new pseudorandom number using the seed and battle info as entropy
        //This makes sure the RNG returns a different number every time
        uint256 randomNumber = uint(keccak256(abi.encodePacked(block.number, chainlinkNumber, battle.player1.playerAddr, battle.player2.playerAddr)));
        return randomNumber;
    }

    function _randMod(uint256 seed, Battle memory battle) private view returns (uint256) {
        uint256 randomNumber = uint(keccak256(abi.encodePacked(seed, battle.currentTurn, battleIdRNGSeed[battle.battleId])));
        return randomNumber;
    }

    //Check if battle ended by looking at player's health
    function checkIfBattleEnded(Battle memory battle) public pure returns (bool, address) {
        if (battle.player1.hand.health <= 0) {
            return (true, battle.player1.playerAddr);
        } else if (battle.player2.hand.health <= 0) {
            return (true, battle.player2.playerAddr);
        } else {
            return (false, address(0));
        }
    }

    function fight(Battle memory battle) public view returns (Battle memory) {
        Hand memory atkHand;
        Hand memory defHand;

        //Get attacker and defender for current turn
        if (battle.attacker == Attacker.PLAYER_ONE) {
            atkHand = battle.player1.hand;
            defHand = battle.player2.hand;
        } else {
            atkHand = battle.player2.hand;
            defHand = battle.player1.hand;
        }

        (atkHand, defHand) = calSupportCardsInHand(atkHand, defHand);

        // Fight

        //Calculate HP loss for defending player
        if (atkHand.currentBCstats.atk > defHand.currentBCstats.def) {
            //If attacker's attack > defender's defense, find difference. That is the defending player's HP loss
            defHand.health -= (atkHand.currentBCstats.atk - defHand.currentBCstats.def);
        } else {
            //Otherwise, defender loses 1 HP
            defHand.health -= 1;
        }

        //Write updated info back into battle
        if (battle.attacker == Attacker.PLAYER_ONE) {
            battle.player1.hand = atkHand;
            battle.player2.hand = defHand;
        } else {
            battle.player1.hand = defHand;
            battle.player2.hand = atkHand;
        }

        return battle;
    }

    
    //We calculate the effect of every card in the player's hand
    function calSupportCardsInHand(Hand memory atkHand, Hand memory defHand) public view returns (Hand memory, Hand memory) {
        // If this card is included in player's hand, adds an additional power equal to the total of
        // all normal offense/defense cards
        bool isPower0CardIncluded = false;
        // Total sum of normal support cards
        int256 totalNormalPower = 0;
        // Cal attacker hand
        for (uint256 i = 0; i < atkHand.currentBCstats.inte; i++) {
            //Loop through every card the attacker has in his hand
            uint256 id = atkHand.supportCardInHandIds[i];

            //Get the support cardStats
            PepemonCardOracle.SupportCardStats memory cardStats = _cardContract.getSupportCardById(id);
            if (cardStats.supportCardType == PepemonCardOracle.SupportCardType.OFFENSE) {
                // Card type is OFFENSE.
                // Calc effects of EffectOne array
                for (uint256 j = 0; j < cardStats.effectOnes.length; j++) {
                    PepemonCardOracle.EffectOne memory effectOne = cardStats.effectOnes[j];
                    
                    //Checks if that support card is triggered and by how much it is triggered by
                    (bool isTriggered, uint256 multiplier) = checkReqCode(atkHand, defHand, effectOne.reqCode, true);
                    if (isTriggered) {
                        //use triggeredPower if triggered
                        atkHand.currentBCstats.atk += effectOne.triggeredPower * int256(multiplier);
                        totalNormalPower += effectOne.triggeredPower * int256(multiplier);
                    }
                    else{
                        //use basePower if not
                        atkHand.currentBCstats.atk += effectOne.basePower;
                        totalNormalPower += effectOne.basePower;
                    }
                }
            } else if (cardStats.supportCardType == PepemonCardOracle.SupportCardType.STRONG_OFFENSE) {
                // Card type is STRONG OFFENSE.

                //Make sure unstackable cards can't be stacked
                if (cardStats.unstackable) {
                    bool isNew = true;
                    // Check if card is new to previous cards
                    for (uint256 j = 0; j < i; j++) {
                        if (id == atkHand.supportCardInHandIds[j]) {
                            isNew = false;
                            break;
                        }
                    }
                    if (!isNew) {
                        //If it isn't - skip card
                        continue;
                    }
                    // Check if card is new to temp support info cards
                    for (uint256 j = 0; j < atkHand.tableSupportCardStats; j++) {
                        if (id == atkHand.tableSupportCards[j].supportCardId) {
                            isNew = false;
                            break;
                        }
                    }
                    if (!isNew) {
                        //If it isn't - skip card
                        continue;
                    }
                }

                // Calc effects of EffectOne array
                for (uint256 j = 0; j < cardStats.effectOnes.length; j++) {
                    PepemonCardOracle.EffectOne memory effectOne = cardStats.effectOnes[j];
                    (bool isTriggered, uint256 multiplier) = checkReqCode(atkHand, defHand, effectOne.reqCode, true);
                    if (isTriggered) {
                        //If triggered: use triggered power
                        if (multiplier > 1) {
                            atkHand.currentBCstats.atk += effectOne.triggeredPower * int256(multiplier);
                        } else {
                            if (effectOne.effectTo == PepemonCardOracle.EffectTo.STRONG_ATTACK) {
                                // If it's a use Special Attack instead of Attack card
                                atkHand.currentBCstats.atk = atkHand.currentBCstats.sAtk;
                                continue;
                            } else if (effectOne.triggeredPower == 0) {
                                // We have a card that says ATK is increased by amount
                                // Equal to the total of all offense cards in the current turn
                                isPower0CardIncluded = true;
                                continue;
                            }
                            atkHand.currentBCstats.atk += effectOne.triggeredPower;
                        }
                    }
                    else{
                        //If not triggered: use base power instead
                        atkHand.currentBCstats.atk += effectOne.basePower;
                        totalNormalPower += effectOne.basePower;
                    }
                }
                // If card lasts for >1 turns
                if (cardStats.effectMany.power != 0) {
                    // Add card  to table if <5 on table currently
                    if (atkHand.tableSupportCardStats < 5) {
                        atkHand.tableSupportCards[atkHand.tableSupportCardStats++] = TableSupportCardStats({
                            supportCardId: id,
                            effectMany: cardStats.effectMany
                        });
                    }
                }
            } else {
                // Other card type is ignored.
                continue;
            }
        }
        if (isPower0CardIncluded) {
            //If we have a card that says ATK is increased by amount equal to total of all offense cards
            atkHand.currentBCstats.atk += totalNormalPower;
        }
        // Cal defense hand
        isPower0CardIncluded = false;
        totalNormalPower = 0;

        for (uint256 i = 0; i < defHand.currentBCstats.inte; i++) {
            uint256 id = defHand.supportCardInHandIds[i];
            PepemonCardOracle.SupportCardStats memory card = _cardContract.getSupportCardById(id);
            if (card.supportCardType == PepemonCardOracle.SupportCardType.DEFENSE) {
                // Card type is DEFENSE
                // Calc effects of EffectOne array
                for (uint256 j = 0; j < card.effectOnes.length; j++) {
                    PepemonCardOracle.EffectOne memory effectOne = card.effectOnes[j];
                    (bool isTriggered, uint256 multiplier) = checkReqCode(atkHand, defHand, effectOne.reqCode, false);
                    if (isTriggered) {
                        defHand.currentBCstats.def += effectOne.triggeredPower * int256(multiplier);
                        totalNormalPower += effectOne.triggeredPower * int256(multiplier);
                    }
                    else{
                        //If not triggered, use base power instead
                        defHand.currentBCstats.def += effectOne.basePower;
                        totalNormalPower += effectOne.basePower;
                    }
                }
            } else if (card.supportCardType == PepemonCardOracle.SupportCardType.STRONG_DEFENSE) {
                // Card type is STRONG DEFENSE
                if (card.unstackable) {
                    bool isNew = true;
                    // Check if card is new to previous cards
                    for (uint256 j = 0; j < i; j++) {
                        if (id == defHand.supportCardInHandIds[j]) {
                            isNew = false;
                            break;
                        }
                    }
                    // Check if card is new to temp support info cards
                    for (uint256 j = 0; j < defHand.tableSupportCardStats; j++) {
                        if (id == defHand.tableSupportCards[j].supportCardId) {
                            isNew = false;
                            break;
                        }
                    }
                    if (!isNew) {
                        continue;
                    }
                }
                // Calc effects of EffectOne array
                for (uint256 j = 0; j < card.effectOnes.length; j++) {
                    PepemonCardOracle.EffectOne memory effectOne = card.effectOnes[j];
                    (bool isTriggered, uint256 num) = checkReqCode(atkHand, defHand, effectOne.reqCode, false);
                    if (isTriggered) {
                        if (num > 0) {
                            defHand.currentBCstats.def += effectOne.triggeredPower * int256(num);
                        } else {
                            if (effectOne.effectTo == PepemonCardOracle.EffectTo.STRONG_DEFENSE) {
                                defHand.currentBCstats.def = defHand.currentBCstats.sDef;
                                continue;
                            } else if (effectOne.triggeredPower == 0) {
                                // Equal to the total of all defense cards in the current turn
                                isPower0CardIncluded = true;
                                continue;
                            }
                            defHand.currentBCstats.def += effectOne.triggeredPower;
                        }
                    }
                    else{
                        //If not triggered, use base stats instead
                        defHand.currentBCstats.def += effectOne.basePower;
                        totalNormalPower += effectOne.basePower;
                    }
                }
                // If card effect lasts >1 turn
                if (card.effectMany.power != 0) {
                    // Add card to table if there are <5 cards on table right now
                    if (defHand.tableSupportCardStats < 5) {
                        defHand.tableSupportCards[defHand.tableSupportCardStats++] = TableSupportCardStats({
                            supportCardId: id,
                            effectMany: card.effectMany
                        });
                    }
                }
            } else {
                // Other card type is ignored.
                continue;
            }
        }
        if (isPower0CardIncluded) {
            //If a "add total of defense" card is included
            defHand.currentBCstats.def += totalNormalPower;
        }

        return (atkHand, defHand);
    }

    //Strip important game information (like speed, intelligence, etc.) from battle card
    function getCardStats(PepemonCardOracle.BattleCardStats memory x) internal pure returns (CurrentBattleCardStats memory){
        CurrentBattleCardStats memory ret;

        ret.spd = int(x.spd);
        ret.inte = x.inte;
        ret.def = int(x.def);
        ret.atk = int(x.atk);
        ret.sAtk = int(x.sAtk);
        ret.sDef = int(x.sDef);

        return ret;
    }

//Checks if the requirements are satisfied for a certain code
//returns bool - is satisfied?
// uint - the multiplier for the card's attack power
// for most cases multiplier is 1
function checkReqCode(
        Hand memory atkHand,
        Hand memory defHand,
        uint256 reqCode,
        bool isAttacker
    ) internal view returns (bool, uint256) {
        bool isTriggered = false;
        uint256 multiplier = 0;
        if (reqCode == 0) {
            // No requirement
            isTriggered = true;
            multiplier = 1;
        } else if (reqCode == 1) {
            // Intelligence of offense pepemon <= 5.
            isTriggered = (atkHand.currentBCstats.inte <= 5 );
            multiplier = 1;

        } else if (reqCode == 2) {
            // Number of defense cards of defense pepemon is 0.
            isTriggered = true;
            for (uint256 i = 0; i < defHand.currentBCstats.inte; i++) {
                PepemonCardOracle.SupportCardType supportCardType = _cardContract.getSupportCardTypeById(
                    defHand.supportCardInHandIds[i]
                );
                if (supportCardType == PepemonCardOracle.SupportCardType.DEFENSE) {
                    isTriggered = false;
                    break;
                }
            }
            multiplier = 1;
        } else if (reqCode == 3) {
            // Each +2 offense cards of offense pepemon.
            for (uint256 i = 0; i < atkHand.currentBCstats.inte; i++) {
                PepemonCardOracle.SupportCardStats memory card = _cardContract.getSupportCardById(
                    atkHand.supportCardInHandIds[i]
                );
                if (card.supportCardType != PepemonCardOracle.SupportCardType.OFFENSE) {
                    continue;
                }
                for (uint256 j = 0; j < card.effectOnes.length; j++) {
                    PepemonCardOracle.EffectOne memory effectOne = card.effectOnes[j];
                    if (effectOne.basePower == 2) {
                        multiplier++;
                    }
                }
            }
            isTriggered = (multiplier > 0 );
        } else if (reqCode == 4) {
            // Each +3 offense cards of offense pepemon.
            for (uint256 i = 0; i < atkHand.currentBCstats.inte; i++) {
                PepemonCardOracle.SupportCardStats memory card = _cardContract.getSupportCardById(
                    atkHand.supportCardInHandIds[i]
                );
                if (card.supportCardType != PepemonCardOracle.SupportCardType.OFFENSE) {
                    continue;
                }
                for (uint256 j = 0; j < card.effectOnes.length; j++) {
                    PepemonCardOracle.EffectOne memory effectOne = card.effectOnes[j];
                    if (effectOne.basePower == 3) {
                        multiplier++;
                    }
                }
            }
            isTriggered = (multiplier > 0 );
        } else if (reqCode == 5) {
            // Each offense card of offense pepemon.
            for (uint256 i = 0; i < atkHand.currentBCstats.inte; i++) {
                PepemonCardOracle.SupportCardStats memory card = _cardContract.getSupportCardById(
                    atkHand.supportCardInHandIds[i]
                );
                if (card.supportCardType != PepemonCardOracle.SupportCardType.OFFENSE) {
                    continue;
                }
                multiplier++;
            }
            isTriggered = (multiplier > 0 );
        } else if (reqCode == 6) {
            // Each +3 defense card of defense pepemon.
            for (uint256 i = 0; i < defHand.currentBCstats.inte; i++) {
                PepemonCardOracle.SupportCardStats memory card = _cardContract.getSupportCardById(
                    defHand.supportCardInHandIds[i]
                );
                if (card.supportCardType != PepemonCardOracle.SupportCardType.DEFENSE) {
                    continue;
                }
                for (uint256 j = 0; j < card.effectOnes.length; j++) {
                    PepemonCardOracle.EffectOne memory effectOne = card.effectOnes[j];
                    if (effectOne.basePower == 3) {
                        multiplier++;
                    }
                }
            }
            isTriggered = (multiplier > 0 );
        } else if (reqCode == 7) {
            // Each +4 defense card of defense pepemon.
            for (uint256 i = 0; i < defHand.currentBCstats.inte; i++) {
                PepemonCardOracle.SupportCardStats memory card = _cardContract.getSupportCardById(
                    defHand.supportCardInHandIds[i]
                );
                if (card.supportCardType != PepemonCardOracle.SupportCardType.DEFENSE) {
                    continue;
                }
                for (uint256 j = 0; j < card.effectOnes.length; j++) {
                    PepemonCardOracle.EffectOne memory effectOne = card.effectOnes[j];
                    if (effectOne.basePower == 4) {
                        multiplier++;
                    }
                }
            }
            isTriggered = (multiplier > 0 );
        } else if (reqCode == 8) {
            // Intelligence of defense pepemon <= 5.
            isTriggered = (defHand.currentBCstats.inte <= 5 );
            multiplier = 1;
        } else if (reqCode == 9) {
            // Intelligence of defense pepemon >= 7.
            isTriggered = (defHand.currentBCstats.inte >= 7 );
            multiplier = 1;
        } else if (reqCode == 10) {
            // Offense pepemon is using strong attack
            for (uint256 i = 0; i < atkHand.currentBCstats.inte; i++) {
                PepemonCardOracle.SupportCardStats memory card = _cardContract.getSupportCardById(
                    atkHand.supportCardInHandIds[i]
                );
                if (card.supportCardType == PepemonCardOracle.SupportCardType.STRONG_OFFENSE) {
                    isTriggered = true;
                    break;
                }
            }
            multiplier = 1;
        } else if (reqCode == 11) {
            // The current HP is less than 50% of max HP.
            if (isAttacker) {
                isTriggered = (
                    atkHand.health * 2 <= int256(_cardContract.getBattleCardById(atkHand.battleCardId).hp)
                );
            } else {
                isTriggered = (
                    defHand.health * 2 <= int256(_cardContract.getBattleCardById(defHand.battleCardId).hp)

                );
            }
            multiplier = 1;
        }
        return (isTriggered, multiplier);
    }
}


