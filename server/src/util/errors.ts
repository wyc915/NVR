/** Error with an HTTP status; Fastify uses `statusCode` for the response. */
export class HttpError extends Error {
  constructor(
    public readonly statusCode: number,
    message: string,
  ) {
    super(message);
  }
}
