# Mercury Bank Integration

The application can connect directly to Mercury Bank using the public API.

## Configuration

Set the following environment variables with the credentials obtained from Mercury:

```
MERCURY_API_KEY=your_api_key
MERCURY_API_SECRET=your_api_secret
```

## Usage

The connection is implemented using a pluggable bank provider architecture.
Mercury can be selected with the provider key `:mercury`.
