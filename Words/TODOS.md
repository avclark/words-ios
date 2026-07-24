# Words Notes & ToDos

- Tapping a tile on the board should not recall it. It should do nothing. (currently, tapping a tile after I've placed it on the board makes it disappear and go back to my rack. This isn't good because when trying to move tiles around on the board I keep accidentally sending them back to the rack.)
- When dragging a tile while the board is zoomed out, the tile should be bigger (approx covering a 6x6 grid). It's current size when zoomed in is right. The only thing that needs to change is when a tile is being dragged when the board is zoomed in. 
- I'm not sure of the logic around when the play button is active vs not active. The play button should only be active when the tiles on the board represent a valid word that can be played. If I place an unconnected tile on the board, or I place a whole word (but it's not a valid word, etc.), the play button should stay inactive. Currently it stays active and if you press it, you get an error saying "that's not a valid word" or something like that. That is actually fine behaviour, but I want the UI of the play button to stay in it's inactive/greyed out state until a playable word is actually on the board. You tell me if right move is to make the button actually inactive until there is a playable word, or keep it active, but make the UI show it as innactive and then when it's tapped the associated error message is displayed.  
- User flow - In my mind the user flow should be Create new account/sign in with apple, and then the first screen you go to is a profile screen where you can set your avatar and username. However, maybe the apple ID can provide the person's name and their avatar by default, but on the profile screen a user can then change their name/avatar?
- Rearrange buttons at the bottom of the screen to make the play button centered. Shuffle and recal on the left, swap and pass on the right. Or just a big centered play button with other options behind a menu. Need to think through this especially when we add in hints/helpers. This whole area needs to be redesigned
- pull to refresh
- passing should pop up a dialog to confirm, bc it's too easy to accidentally tap
- Fuzzy search. Currently search only returns results that are exact matches
- highlight for hints UI needs improvement
- also, we we should have three levels instead of two (red/green): Red for best word available, yellow (or some other color) for second best word, green for the rest. (or whatever colors make the most sense).
- When reviewing a game, let's add definition underneath the best words that could have been played, but weren't (for example: garrets - see screenshot)

## App screens
- Sign in/up
- Home
  - This is the lobby
  - Game logo at top of the screen
  - Big New Game button
  - List of active games delineated by Your Turn and Their Turn
- Friends
  - A list of all friends both active and pending
  - Search users
  - Share invite link
- Leaderboard
  - This is the stats page - or maybe this is different than the stats page, but it's a public page that shows you're ranking, win rate, number of wins, number of games played, etc. And this is public. It's global across the whole app, but scoped to you and your friends. 
- Profile
  - Set username / display name
  - Upload avatar
  - Stats (probably the current stats we have but expanded)
  - Sub page: Profile Settings
    - Username / display name
    - Avatar
    - Notifications settings
    - Other settings
    - Sign out
    - Account deletion
    - Terms / Legal / Privacy