# Phpscan GitHub Action

Using this GitHub Action, scan your code with phpscan scanner (SaaS https://phpscan.com/) to detect vulnerabilities in php code.

## Requirements

* You need to register at https://phpscan.com/. Get a free API key in your profile.
* That's all!

### Inputs

These are some of the supported input parameters of action.

- `auth_token` - **_(Required)_** this is the API key for accessing the check service https://phpscan.com/
- `project_name` - Name of the project that will be displayed on https://phpscan.com/ web interface.


## Usage

First, add secret variable (see https://docs.github.com/en/actions/security-guides/encrypted-secrets).

Secret variable name: PHPSCAN_AUTH_TOKEN

Secret variable value: get it for free in your profile on the site https://phpscan.com/

Second, create the workflow, usually declared in `.github/workflows/build.yaml`, looks like:
```yaml
name: GitHub Actions Phpscan
on:
  push:
    branches:
      - master
jobs:
  Phpscan-Action:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v3
      - name: Phpscan Vulnerabilities Scanner
        uses: phpscan/phpscan_action@v0.1.7
        env:
          PHPSCAN_AUTH_TOKEN: ${{ secrets.PHPSCAN_AUTH_TOKEN }}
```

You can change the project name by using the optional input like this:
```yaml
      - name: Phpscan Vulnerabilities Scanner
        uses: phpscan/phpscan_action@v0.1.7
        env:
          PHPSCAN_AUTH_TOKEN: ${{ secrets.PHPSCAN_AUTH_TOKEN }}
          PROJECT_NAME: "your project name"
```
