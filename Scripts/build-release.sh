#!/bin/bash

set -e

echo "============================================"
echo "🚀 Cok Release Helper"
echo "============================================"

if [ -z "$1" ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 v0.1.0"
    echo ""
    echo "This script helps you create a new release:"
    echo "1. Creates and pushes a git tag"
    echo "2. Provides instructions for GitHub Actions"
    exit 1
fi

VERSION="$1"

# Validate version format
if [[ ! "$VERSION" =~ ^v0\.[0-9]+\.[0-9]+$ ]]; then
    echo "❌ Invalid version format. Use v0.X.Y for pre-1.0 releases (e.g., v0.1.0)"
    exit 1
fi

echo "Creating release for version: $VERSION"
echo ""

# Check if tag already exists
if git rev-parse "$VERSION" >/dev/null 2>&1; then
    echo "❌ Tag $VERSION already exists!"
    echo "Use: git tag -d $VERSION && git push origin :refs/tags/$VERSION"
    echo "To delete the existing tag first."
    exit 1
fi

# Create and push tag
echo "📝 Creating git tag..."
git tag "$VERSION"
git push origin "$VERSION"

echo ""
echo "✅ Tag created and pushed successfully!"
echo ""
echo "============================================"
echo "🎯 Next Steps:"
echo "============================================"
echo ""
echo "1. Go to GitHub Actions in your repository:"
echo "   https://github.com/$(git config --get remote.origin.url | sed 's/.*github.com[:/]\([^.]*\).*/\1/')/actions"
echo ""
echo "2. Click on 'Release' workflow"
echo ""
echo "3. Click 'Run workflow' button"
echo ""
echo "4. Enter version: $VERSION (e.g., v0.1.0, v0.2.0)"
echo ""
echo "5. Click 'Run workflow' to start the build"
echo ""
echo "6. Wait for the workflow to complete (~5-10 minutes)"
echo ""
echo "7. Copy the generated formula from workflow output"
echo ""
echo "8. Update your homebrew-tap repository"
echo ""
echo "============================================"
echo "📦 What will be built:"
echo "============================================"
echo "• macOS ARM64 binary"
echo "• macOS x86_64 binary" 
echo "• Linux x86_64 binary"
echo "• SHA256 checksums"
echo "• GitHub release with all artifacts"
echo "• Updated Homebrew formula"
echo ""
echo "Users will be able to install with:"
echo "  brew tap annurdien/tap"
echo "  brew install cok"