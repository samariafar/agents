# Contribution Guide

We appreciate your interest in contributing to this project! This document outlines the process for submitting code, documentation, or other types of contributions. Please read and follow these guidelines to ensure a smooth collaboration with the project maintainers.

Before participating in the project, please read our [Code of Conduct](https://github.com/{repoFullName}?tab=coc-ov-file#readme). By engaging with this repository and its respective community, you agree to abide by its terms.

## 💻 Setting up your development environment

1. [Fork](https://github.com/{repoFullName}/fork) the project on _GitHub_ to your own account.
    - If you are new to forking repositories, you can find a detailed guide on forking [here](https://docs.github.com/en/get-started/quickstart/fork-a-repo).
2. Clone your fork to your local development environment:
    ```
    git clone git@github.com:{repoFullName}.git
    cd {projectName-lowercased}
    ```
3. Make sure you have the necessary tools installed, such as _{primaryLanguage}_ and any dependencies required by the project.

**NOTE:** If you'd like to contribute to our documentation, please use [MyRepos](https://myrepos.branchable.com) tool to clone the project's _Wiki_. You can initiate the clone by running `mr checkout` as configured in the `.mrconfig` file. This will create the sub-repository under the `docs/wiki/` directory, separate from the main repository. To interact with this sub-repository, it's important to familiarize yourself with other `mr` commands.

## 📐 Coding conventions and best practices

When contributing to this project, please adhere to the following guidelines:

1. **Coding Conventions:** {codingConventionsBody}
2. **Code Refactoring:** Consider using refactoring techniques to improve the structure of existing code without changing its behavior. Familiarize yourself with various design patterns that can make your code more efficient, scalable, and maintainable. You can find comprehensive guides and examples at [Refactoring Guru](https://refactoring.guru/).
3. **Cross-Platform Compatibility:** {crossPlatformBody}
4. **Performance Optimization:** {performanceBody}
5. **Testing:** {testingBody}

## 📤 Submitting your contribution

1. Create a new branch for your contribution:
    ```
    git checkout -b feature/your-feature
    ```
2. Make your changes and commit them with a descriptive message:
    ```
    git add .
    git commit -m "Add a brief description of your changes"
    ```
    - Writing clear and concise commit messages is important. For tips on how to write good commit messages, you can refer to [this guide](https://chris.beams.io/posts/git-commit/) tailored for projects following the _Gitflow_ approach.
3. Push your changes to your fork on _GitHub_:
    ```
    git push origin feature/your-feature
    ```
4. Create a pull request on the project's _GitHub_ repository, comparing the project's `develop` branch with your feature branch.
5. Fill out the pull request template with a description of your changes, and reference any relevant issues or discussions.

## 🧐 Review process

After submitting your pull request, the project maintainers will review your contribution. They may request changes or provide feedback before merging your changes into the development branch. Please be patient and address any comments or concerns raised by the maintainers.

<br>

💖 Thank you for your contribution! Your collaboration helps improve the project for everyone.
