# Wise Bank Integration

The application can connect directly to Wise using the public API.

## Configuration

Set the following environment variable with your API token:

```
WISE_API_TOKEN=your_token
```

## Usage

The connection is implemented using the pluggable bank provider architecture.
Wise can be selected with the provider key `:wise`.
