// Legacy annotation keys (deprecated, use getSiteAnnotationKey instead)
export const SITE_ANNOTATIONS = {
    domain: "voxeil.com/domain",
    tlsEnabled: "voxeil.com/tls-enabled",
    tlsIssuer: "voxeil.com/tls-issuer",
    image: "voxeil.com/image",
    containerPort: "voxeil.com/container-port",
    cpu: "voxeil.com/cpu",
    ramGi: "voxeil.com/ramGi",
    diskGi: "voxeil.com/diskGi",
    mailEnabled: "voxeil.com/mail-enabled",
    mailProvider: "voxeil.com/mail-provider",
    mailDomain: "voxeil.com/mail-domain",
    mailStatus: "voxeil.com/mail-status",
    mailLastError: "voxeil.com/mail-last-error",
    dnsEnabled: "voxeil.com/dns-enabled",
    dnsDomain: "voxeil.com/dns-domain",
    dnsTarget: "voxeil.com/dns-target",
    githubEnabled: "voxeil.com/github-enabled",
    githubRepo: "voxeil.com/github-repo",
    githubBranch: "voxeil.com/github-branch",
    githubWorkflow: "voxeil.com/github-workflow",
    githubImage: "voxeil.com/github-image",
    dbEnabled: "voxeil.com/db-enabled",
    dbName: "voxeil.com/db-name",
    dbUser: "voxeil.com/db-user",
    dbHost: "voxeil.com/db-host",
    dbPort: "voxeil.com/db-port",
    dbSecret: "voxeil.com/db-secret"
};

// Site annotation property names (without prefix)
export const SITE_ANNOTATION_PROPS = {
    domain: "domain",
    tlsEnabled: "tlsEnabled",
    tlsIssuer: "tlsIssuer",
    image: "image",
    containerPort: "containerPort",
    cpu: "cpu",
    ramGi: "ramGi",
    diskGi: "diskGi",
    mailEnabled: "mailEnabled",
    mailProvider: "mailProvider",
    mailDomain: "mailDomain",
    mailStatus: "mailStatus",
    mailLastError: "mailLastError",
    dnsEnabled: "dnsEnabled",
    dnsDomain: "dnsDomain",
    dnsTarget: "dnsTarget",
    githubEnabled: "githubEnabled",
    githubRepo: "githubRepo",
    githubBranch: "githubBranch",
    githubWorkflow: "githubWorkflow",
    githubImage: "githubImage",
    dbEnabled: "dbEnabled",
    dbName: "dbName",
    dbUser: "dbUser",
    dbHost: "dbHost",
    dbPort: "dbPort",
    dbSecret: "dbSecret"
};

/**
 * Get site annotation key in new format: voxeil.io/site-{slug}-{prop}
 */
export function getSiteAnnotationKey(slug, prop) {
    return `voxeil.io/site-${slug}-${prop}`;
}

/**
 * Get site annotation value from annotations object (supports both old and new format)
 */
export function getSiteAnnotation(annotations, slug, prop) {
    const newKey = getSiteAnnotationKey(slug, prop);
    const oldKey = SITE_ANNOTATIONS[prop];
    return annotations[newKey] ?? annotations[oldKey];
}
