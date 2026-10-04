import {S3Client, HeadObjectCommand, GetObjectCommand, PutObjectCommand, DeleteObjectCommand} from '@aws-sdk/client-s3';
type Metadata = {contentType?: string; size?: number; cacheControl?: string; metadata?: Record<string, string>};
export class AssetStore {
  constructor(readonly client: S3Client, readonly bucket: string) {}
  file(path: string): AssetFile {
    if (!/^(tmp|pairs|private)\/[a-zA-Z0-9_/-]+$/.test(path) || path.includes('..') || path.includes('//')) throw new Error('invalid_asset_path');
    return new AssetFile(this.client, this.bucket, path);
  }
}
class AssetFile {
  constructor(readonly client: S3Client, readonly bucket: string, readonly path: string) {}
  async exists(): Promise<[boolean]> {
    try {await this.getMetadata(); return [true];}
    catch (error) {if ((error as {$metadata?: {httpStatusCode?: number}}).$metadata?.httpStatusCode === 404) return [false]; throw error;}
  }
  async download(): Promise<[Buffer]> {
    const response = await this.client.send(new GetObjectCommand({Bucket: this.bucket, Key: this.path}));
    if (!response.Body) throw new Error('asset_empty');
    return [Buffer.from(await response.Body.transformToByteArray())];
  }
  async getMetadata(): Promise<[Metadata]> {
    const value = await this.client.send(new HeadObjectCommand({Bucket: this.bucket, Key: this.path}));
    return [{contentType: value.ContentType, size: value.ContentLength, metadata: value.Metadata}];
  }
  async save(bytes: Buffer, options: {resumable?: boolean; preconditionOpts?: {ifGenerationMatch: number}; metadata: Metadata}): Promise<void> {
    try {
      await this.client.send(new PutObjectCommand({Bucket: this.bucket, Key: this.path, Body: bytes, ContentLength: bytes.length,
        ContentType: options.metadata.contentType, CacheControl: 'private, no-store', Metadata: options.metadata.metadata, IfNoneMatch: '*'}));
    } catch (error) {
      if ((error as {$metadata?: {httpStatusCode?: number}}).$metadata?.httpStatusCode === 412) throw Object.assign(new Error('asset_exists'), {code: 412});
      throw error;
    }
  }
  async delete(): Promise<void> {await this.client.send(new DeleteObjectCommand({Bucket: this.bucket, Key: this.path}));}
}
