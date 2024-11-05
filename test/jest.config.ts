
import type { Config } from 'jest';

const config: Config = {
  watch: false,
  preset: 'ts-jest/presets/js-with-ts',
  testEnvironment: 'node',
  globalSetup: '<rootDir>/global-setup.ts',
  globalTeardown: '<rootDir>/global-teardown.ts',
  workerThreads: true ,
  testTimeout: 30_000,
  transformIgnorePatterns: [
    '/node_modules/(?!@dfinity/agent|@dfinity/certificate-verification)' // Add other modules as necessary
  ]
};


export default config;