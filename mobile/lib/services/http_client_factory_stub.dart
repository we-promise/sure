import 'package:http/http.dart' as http;

http.Client createHttpClient(List<int>? trustedCertificateBytes) =>
    http.Client();
