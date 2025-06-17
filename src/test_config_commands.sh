#!/bin/bash

echo "Testing new config path commands..."
echo ""

echo "1. Show current config path:"
./macrowhisper --get-config
echo ""

echo "2. Set a custom config path:"
./macrowhisper --set-config ~/test-configs/
echo ""

echo "3. Show updated config path:"
./macrowhisper --get-config
echo ""

echo "4. Test reveal config (should open the custom path):"
echo "   ./macrowhisper --reveal-config"
echo ""

echo "5. Reset to default:"
./macrowhisper --reset-config
echo ""

echo "6. Show config path after reset:"
./macrowhisper --get-config
echo ""

echo "7. Test with explicit file path:"
./macrowhisper --set-config ~/test-configs/custom-config.json
echo ""

echo "8. Show final config path:"
./macrowhisper --get-config
echo ""

echo "Test complete!" 