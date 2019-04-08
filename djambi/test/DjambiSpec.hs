module DjambiSpec where

import           Control.Monad
import           Data.Aeson                (ToJSON, encode)
import           Data.Either               (fromRight)
import           Data.Functor
import           Data.List                 (sort)
import           Data.Maybe
import           Data.String               (fromString)
import           Data.Text.Lazy            (unpack)
import           Data.Text.Lazy.Encoding   (decodeUtf8)
import           Djambi
import           Djambi.Server
import           Network.HTTP.Types.Method
import           Test.Hspec
import           Test.Hspec.Wai            hiding (pendingWith)
import           Test.QuickCheck

-- Plan
--
--  1. [x] setup basic types for (pure) game logic
--     - get current Game
--     - get possible plays :: Game -> [ Play ]
--     - apply a Play on a Game
--     1.1 list possible plays
--       - use same type for rows and cols
--  2. [x] scaffold HTTP server to serve JSON
--  3. [x] handle logical errors
--  4. enrich game play
--     a'. add one player to handle game turn
--     a. more pieces: Necromobile, Journaliste, Provocateur, Assassin, Chef
--     b. kill a piece
--     c. end game
--  4. plug https://github.com/berewt/J2S to get an AI opponent
--  5. provide HTML Content type

validplay = Play Vert (C, 1) (D, 1)
invalidPlay = Play Vert (C,1) (D, 3)

spec :: Spec
spec = describe "Djambi Game" $ do

  with djambiApp $ describe "Djambi Server" $ do
    let json :: (ToJSON a) => a -> ResponseMatcher
        json = fromString . unpack . decodeUtf8 . encode

    it "on GET /game returns state of the game as JSON" $
      get "/game" `shouldRespondWith` json initialBoard

    it "on GET /possible-moves returns list of valid plays for current player as JSON" $
      get "/possible-moves" `shouldRespondWith` json (allPossibleMoves initialGame)

    it "on POST /move returns updated board as JSON given move is legal" $ do
      let move = encode validplay
          Right updatedGame = play validplay initialGame
      request methodPost "/move" [("content-type", "application/json")] move `shouldRespondWith` json (getBoard updatedGame)

    it "on POST a second /move returns updated board" $ do
      let firstMove = encode validplay
          secondPlay = Play Rouge (A, 7) (A, 6)
          secondMove = encode secondPlay
          Right updatedGame = play validplay initialGame >>= play secondPlay
      request methodPost "/move" [("content-type", "application/json")] firstMove
      request methodPost "/move" [("content-type", "application/json")] secondMove `shouldRespondWith` json (getBoard updatedGame)

    it "on POST /move returns error 400 given move is invalid" $ do
      let move = encode invalidPlay
      request methodPost "/move" [("content-type", "application/json")] move `shouldRespondWith` 400

  describe "Core Game Logic" $ do

    it "returns initial board when there is no play" $
      getBoard initialGame  `shouldBe` initialBoard

    it "updates the game state when playing, given a valid play" $ do
      let updatedGame = Game [validplay]
      play validplay initialGame  `shouldBe` Right updatedGame

    describe "Coordinates computation" $ do
      it "can compute abstract movement of a piece horizontally" $ do
          moveOnePosition (C, 1) East  `shouldBe` pure (C, 2)
          moveOnePosition (C, 2) East  `shouldBe` pure (C, 3)
          moveOnePosition (C, 2) East  `shouldBe` pure (C, 3)
          moveOnePosition (C, 9) East  `shouldBe` mempty
          moveOnePosition (C, 9) West  `shouldBe` pure (C, 8)
          moveOnePosition (D, 7) West  `shouldBe` pure (D, 6)
          moveOnePosition (D, 7) East  `shouldBe` pure (D, 8)

      it "can compute abstract movement of a piece vertically" $ do
          moveOnePosition (C, 1) South  `shouldBe` pure (D, 1)
          moveOnePosition (I, 1) South  `shouldBe` mempty
          moveOnePosition (C, 1) North  `shouldBe` pure (B, 1)
          moveOnePosition (A, 1) North `shouldBe` mempty
          moveOnePosition (C, 3) North  `shouldBe` pure (B, 3)
          moveOnePosition (C, 3) South  `shouldBe` pure (D, 3)

      it "can compute abstract movement of a piece diagonally" $ do
          moveOnePosition (C, 1) SE  `shouldBe` pure (D, 2)
          moveOnePosition (C, 2) SW  `shouldBe` pure (D, 1)
          moveOnePosition (C, 1) NE  `shouldBe` pure (B, 2)
          moveOnePosition (C, 2) NW  `shouldBe` pure (B, 1)

    it "generates a list of possible plays for militant" $ do
      --  1 2 3
      -- A.   .
      -- B. .
      -- C+ . .
      -- D. .
      -- E.   .
      possibleMoves initialBoard Vert (C, 1)
        `shouldBe` sort [Play Vert (C, 1) p | p <- [(D, 1), (D, 2), (E, 1), (E, 3)]]

      possibleMoves initialBoard Vert (A, 3)
        `shouldBe` sort [Play Vert (A, 3) p | p <- [(A, 4), (B, 4), (A, 5), (C, 5)]]

      possibleMoves initialBoard Vert (B, 1) `shouldBe` []

    it "generates a list of all possible moves" $ do
      allPossibleMoves initialGame `shouldContain` possibleMoves initialBoard Vert (C,1)
      allPossibleMoves initialGame `shouldContain` possibleMoves initialBoard Vert (C,2)

    it "rejects play if it is not valid" $
      -- The game piece in C1 is a activist, so it can only move by
      -- one or two steps horizontally, vertically or diagonally,
      -- making this move invalid
      play invalidPlay initialGame  `shouldBe` Left (InvalidPlay invalidPlay)

    it "returns updated board when there are 2 plays" $
      getBoardFrom (Board [Militant Vert (C,1), Militant Rouge (A,7)]) <$> (play (Play Rouge (A, 7) (A, 6)) =<< play validplay initialGame)
        `shouldBe` Right (Board [ Militant Vert (D,1), Militant Rouge (A,6) ])

    describe "Next Player Logic" $ do

      it "gives Vert as next player when starting game" $
        getNextPlayer initialGame `shouldBe` Vert

      it "gives Rouge after a valid play" $
        getNextPlayer <$> play validplay initialGame `shouldBe` Right Rouge

      it "gives Bleu after a valid play by Rouge" $ do
        let twoPlays = do
              intermediate <- play validplay initialGame
              play (Play Rouge (A, 7) (A, 6)) intermediate
        getNextPlayer <$> twoPlays `shouldBe` Right Bleu

      it "gives Jaune after a valid play by Bleu" $ do
         let threePlays = foldM (flip play) initialGame [validplay, Play Rouge (A, 7) (A, 6), Play Bleu (G, 7) (F, 6)]
         getNextPlayer <$> threePlays `shouldBe` Right Jaune

      it "gives Vert after a valid play by Jaune" $ do
         let fourPlays = foldM (flip play) initialGame [validplay, Play Rouge (A, 7) (A, 6), Play Bleu (G, 7) (F, 6), Play Jaune (G, 2) (F, 2)]
         getNextPlayer <$> fourPlays `shouldBe` Right Vert

