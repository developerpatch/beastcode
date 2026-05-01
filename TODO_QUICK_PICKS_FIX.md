# Plan: Fix YT Music Quick Picks Implementation

## Problem Analysis
The user has provided YT Music cookies and connected Google account, but Quick Picks are not showing. Need to add better visibility into what's happening.

## Information Gathered
1. App has multiple Quick Picks fetch strategies:
   - Backend proxy (optional)
   - WebView extraction (Android/iOS/macOS)
   - Innertube API direct

2. Current flow in `_loadHome()`:
   - Calls `_buildYtMusicHomeExperience()`
   - Tries backend → WebView → Innertube
   - Stores results in `_quickRow1`

3. Session validation happens via `_refreshYtMusicSession()`
   - Validates cookie presence
   - Fetches account info
   - Sets `_ytMusicSessionValid`

## Plan

### Step 1: Add Quick Refresh Button in Home Screen
- Add a refresh icon in the Quick Picks header
- Allow users to manually reload Quick Picks

### Step 2: Add Status Indicator in Quick Picks Row
- Show loading state
- Show error state with specific message
- Show success with count

### Step 3: Add Debug Info in Settings
- Show cookie validation status
- Show session verification status
- Show what method is being used (WebView/Innertube)

### Step 4: Improve Error Handling
- Add better logging throughout the Quick Picks flow
- Show specific error messages

## Dependent Files to Edit
- `lib/main.dart` - Main implementation file

## Followup Steps
1. Test the app after changes
2. Check debug logs to verify Quick Picks are being fetched

