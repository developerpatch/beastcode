# Implementation Plan - Debug Mode Toggle

## Information Gathered:
- The project is a Flutter app (Beast Music) with YouTube Music integration
- There's already a `_debugModeEnabled` boolean variable in the code
- The settings are built in `_buildSettingsTab()` method  
- There's a "YouTube Music Account" section in settings with session verification
- There's a "Developer" section with `Icons.code_rounded`
- SharedPreferences is used for persistence

## Plan:

### Task 1: Add Debug Mode Preference Key Constant
- Add a static constant for the debug mode preference key

### Task 2: Load Debug Mode Preference
- Load `_debugModeEnabled` from SharedPreferences in `_loadData()`

### Task 3: Add Save Method for Debug Mode
- Add a method to save debug mode preference to SharedPreferences

### Task 4: Add Debug Mode Toggle in Settings UI
- Add a toggle in the "YouTube Music Account" section or Developer section
- Use a Switch widget to toggle debug mode
- Call the save method when toggled

## Implementation:

### Step 1: Add preference key constant (around line with other pref keys)
### Step 2: Load debug mode in _loadData() 
### Step 3: Add save method
### Step 4: Add toggle in _buildSettingsTab() UI

## Follow-up Steps:
- Test the debug mode toggle works correctly
- Verify debug logs appear when enabled

