#!/usr/bin/env bash
set -euxo pipefail

# Install latest brew
if [[ $(command -v brew) == "" ]]; then
  echo "Installing brew in order to build MetaCall"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Install brew-pkg
brew tap --verbose metacall/brew-pkg
brew install --verbose --HEAD metacall/brew-pkg/brew-pkg

# Overwrite installed brew-pkg with your local debug version
BREWPKG_PATH=$(brew --prefix)/Cellar/brew-pkg/*/bin/brew-pkg.rb
echo "Overwriting brew-pkg script at: $BREWPKG_PATH"
cp brew-pkg.rb $BREWPKG_PATH

# Test Python with dependencies, compress and custom output tarball name
brew install python@3.12
brew pkg --name python --with-deps --compress python@3.12
test -f python.tar.gz
test -f python.pkg

brew pkg --name python-without-deps --compress python@3.12
test -f python-without-deps.tar.gz
test -f python-without-deps.pkg

brew install ruby@3.3
brew pkg --name ruby-with-python --compress --relocatable --additional-deps python@3.12 ruby@3.3
test -f ruby-with-python.tar.gz
test -f ruby-with-python.pkg

# Debug files and sizes
echo "=== Final package sizes ==="
ls -lh python.tar.gz python.pkg python-without-deps.tar.gz python-without-deps.pkg ruby-with-python.tar.gz ruby-with-python.pkg

# Verify symlinks exist in the lib directory inside each tarball
echo "=== Verifying lib symlinks in python.tar.gz ==="
tar -ztvf python.tar.gz | grep "opt/homebrew/lib" || echo "WARN: No symlinks found under opt/homebrew/lib in python.tar.gz"

echo "=== Verifying lib symlinks in python-without-deps.tar.gz ==="
tar -ztvf python-without-deps.tar.gz | grep "opt/homebrew/lib" || echo "WARN: No symlinks found under opt/homebrew/lib in python-without-deps.tar.gz"

echo "=== Verifying lib symlinks in ruby-with-python.tar.gz ==="
tar -ztvf ruby-with-python.tar.gz | grep "opt/homebrew/lib" || echo "WARN: No symlinks found under opt/homebrew/lib in ruby-with-python.tar.gz"