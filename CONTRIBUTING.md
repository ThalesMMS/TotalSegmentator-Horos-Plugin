# Contributing to TotalSegmentator Horos Plugin

Thank you for your interest in contributing to the TotalSegmentator Horos Plugin! This document provides guidelines and best practices for contributing to this project.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Development Setup](#development-setup)
- [Code Quality Standards](#code-quality-standards)
- [Testing](#testing)
- [Pull Request Process](#pull-request-process)
- [Project Structure](#project-structure)

## Code of Conduct

- Be respectful and inclusive in all communications
- Focus on constructive feedback
- Help create a welcoming environment for all contributors

## Development Setup

### Prerequisites

- macOS 14.0 or later
- Xcode 15 or later
- Horos 4.0.1 or later
- Python 3.9 or later
- Git

### Setting Up the Development Environment

1. **Clone the repository:**
   ```bash
   git clone https://github.com/ThalesMMS/TotalSegmentator-Horos-Plugin.git
   cd TotalSegmentator-Horos-Plugin
   ```

2. **Open the Xcode project:**
   ```bash
   open MyOsiriXPluginFolder-Swift/TotalSegmentatorHorosPlugin.xcodeproj
   ```

3. **Install Python development dependencies:**
   ```bash
   pip install -e ".[dev]"
   ```

4. **Install pre-commit hooks:**
   ```bash
   pip install pre-commit
   pre-commit install
   ```

5. **Install SwiftLint (optional but recommended):**
   ```bash
   brew install swiftlint
   ```

## Code Quality Standards

### Swift Code

- Follow Swift API Design Guidelines
- Use meaningful variable and function names
- Keep functions small and focused (max 100 lines)
- Add documentation comments for public APIs using `///` style
- Use MARK comments to organize code sections
- Run SwiftLint before committing: `swiftlint`

#### Swift Style Guidelines

```swift
// MARK: - Good Examples

/// Calculate the sum of two integers.
/// - Parameters:
///   - a: First integer
///   - b: Second integer
/// - Returns: Sum of a and b
func add(_ a: Int, _ b: Int) -> Int {
    return a + b
}

// MARK: - Bad Examples

// Don't use single-letter function names
func a(_ x: Int, _ y: Int) -> Int {
    return x + y
}
```

### Python Code

- Follow PEP 8 style guide
- Use type hints for all function parameters and return values
- Add docstrings for all public functions and classes
- Keep functions focused and under 50 lines when possible
- Use Ruff for linting: `ruff check .`

#### Python Style Guidelines

```python
# Good Example
def calculate_volume(width: float, height: float, depth: float) -> float:
    """
    Calculate the volume of a rectangular prism.

    Args:
        width: Width in millimeters
        height: Height in millimeters
        depth: Depth in millimeters

    Returns:
        Volume in cubic millimeters

    Raises:
        ValueError: If any dimension is negative
    """
    if width < 0 or height < 0 or depth < 0:
        raise ValueError("Dimensions must be non-negative")
    return width * height * depth

# Bad Example
def calc(w, h, d):
    return w * h * d
```

### Commit Messages

- Use clear, descriptive commit messages
- Start with a verb in imperative mood (e.g., "Add", "Fix", "Update")
- Keep first line under 50 characters
- Add detailed description if needed after blank line

Example:
```
Add type hints to python_api.py functions

- Added type hints to all public API functions
- Improved documentation with detailed docstrings
- Enhanced error messages for better debugging
```

## Testing

### Python Tests

Run the Python test suite:

```bash
cd tests
pytest test_end_to_end.py -v
pytest test_locally.py -v
```

### Swift/Plugin Tests

Currently, the Swift plugin does not have automated tests. Manual testing procedure:

1. Build the plugin in Xcode
2. Copy to Horos plugins directory:
   ```bash
   cp -r build/Release/TotalSegmentatorHorosPlugin.osirixplugin \
      ~/Library/Application\ Support/Horos/Plugins/
   ```
3. Restart Horos
4. Test with sample DICOM data

## Pull Request Process

1. **Create a feature branch:**
   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes:**
   - Write clean, documented code
   - Add tests if applicable
   - Update documentation if needed

3. **Run quality checks:**
   ```bash
   # Python
   ruff check .
   ruff format --check .
   pytest

   # Swift (if SwiftLint is installed)
   swiftlint
   ```

4. **Commit your changes:**
   ```bash
   git add .
   git commit -m "Add your descriptive commit message"
   ```

5. **Push to your fork:**
   ```bash
   git push origin feature/your-feature-name
   ```

6. **Create a Pull Request:**
   - Go to GitHub and create a PR from your branch
   - Provide a clear description of changes
   - Reference any related issues
   - Wait for code review

## Project Structure

```
TotalSegmentator-Horos-Plugin/
├── MyOsiriXPluginFolder-Swift/     # Swift plugin source code
│   ├── Plugin.swift                 # Main plugin implementation
│   ├── *WindowController.swift     # UI controllers
│   └── *.xib                        # Interface Builder files
├── totalsegmentator/                # Python TotalSegmentator library
│   ├── python_api.py               # Main Python API
│   ├── nnunet.py                   # nnUNet inference
│   ├── libs.py                     # Utility functions
│   └── bin/                        # CLI scripts
├── tests/                           # Python test suite
├── resources/                       # Documentation and helper scripts
├── README.md                        # Project documentation
├── CONTRIBUTING.md                  # This file
├── .swiftlint.yml                  # SwiftLint configuration
├── pyproject.toml                   # Python linting config
└── setup.py                         # Python package setup
```

## Key Areas for Contribution

### High Priority
- Automated testing for Swift plugin
- Performance optimizations
- Error handling improvements
- Documentation updates

### Medium Priority
- Additional segmentation tasks
- UI/UX improvements
- Better progress reporting
- Localization support

### Low Priority
- Code refactoring
- Style improvements
- Additional helper scripts

## Questions?

If you have questions or need help, please:
1. Check the [README.md](README.md) first
2. Search existing GitHub issues
3. Create a new issue with your question

Thank you for contributing to TotalSegmentator Horos Plugin!
