# Contributing to core_data

First off, thank you for considering contributing to Git AI Reporter! It's people like you that make core_data such a great tool.

## Code of Conduct

This project follows standard open source collaboration practices. Please be respectful and constructive in all interactions. Please report any unacceptable behavior to [paudley@blackcat.ca](mailto:paudley@blackcat.ca).

## How Can I Contribute?

### Reporting Bugs

Before creating bug reports, please check [existing issues](https://github.com/paudley/core_data/issues) as you might find out that you don't need to create one. When you are creating a bug report, please include as many details as possible:

* **Use a clear and descriptive title**
* **Describe the exact steps to reproduce the problem**
* **Provide specific examples to demonstrate the steps**
* **Describe the behavior you observed and what you expected**
* **Include logs and error messages**
* **Include your environment details** (OS, Python version, git-ai-reporter version)

### Suggesting Enhancements

Enhancement suggestions are tracked as [GitHub issues](https://github.com/paudley/core_data/issues). When creating an enhancement suggestion:

* **Use a clear and descriptive title**
* **Provide a detailed description of the suggested enhancement**
* **Provide specific examples to demonstrate the use case**
* **Describe the current behavior and explain the expected behavior**
* **Explain why this enhancement would be useful**

### Pull Requests

1. Fork the repo and create your branch from `main`
2. Follow the setup instructions in the README
3. Make your changes following our coding standards
4. Add or update tests as needed
5. Ensure the test suite passes
6. Update documentation as needed
7. Submit your pull request!

## Development Setup

### Prerequisites

- Git
- Docker

### Setting Up Your Development Environment

```bash
# Clone your fork
git clone https://github.com/paudley/core_data.git
cd core_data
```

## Documentation

- Update the README.md if you change functionality
- Update inline documentation and docstrings
- Add entries to PENDING.md for future enhancements

## Commit Messages

We follow [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` New feature
- `fix:` Bug fix
- `docs:` Documentation only changes
- `style:` Code style changes (formatting, etc.)
- `refactor:` Code change that neither fixes a bug nor adds a feature
- `perf:` Performance improvement
- `test:` Adding or updating tests
- `chore:` Changes to build process or auxiliary tools

Examples:
```
feat: add support for GitLab repositories
fix: handle empty commit messages gracefully
docs: update installation instructions for Windows
test: add integration tests for weekly summaries
```

## Questions?

Feel free to open an issue with the "question" label or reach out to the maintainers.

## License

By contributing, you agree that your contributions will be licensed under the MIT License (SPDX: MIT).

All source code files should include the SPDX license identifier at the top:
```python
# SPDX-License-Identifier: MIT
# Copyright (c) 2025 Blackcat Informatics® Inc.
```

## Acknowledgments

Thank you to all contributors who help make core_data better!
