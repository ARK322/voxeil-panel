export default {
  testEnvironment: 'node',
  transform: {},
  moduleNameMapper: {},
  testMatch: ['**/*.test.js', '**/*.spec.js'],
  collectCoverageFrom: [
    '**/*.js',
    '!**/node_modules/**',
    '!**/jest.config.js'
  ],
  passWithNoTests: true
};
