export default {
  testEnvironment: 'node',
  transform: {},
  extensionsToTreatAsEsm: ['.js'],
  moduleNameMapper: {},
  testMatch: ['**/*.test.js', '**/*.spec.js'],
  collectCoverageFrom: [
    '**/*.js',
    '!**/node_modules/**',
    '!**/jest.config.js'
  ],
  passWithNoTests: true
};
