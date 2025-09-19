pipeline {
  agent {
    kubernetes {
      label "node-kaniko-${UUID.randomUUID().toString()}"
      defaultContainer 'node'
      yaml """
apiVersion: v1
kind: Pod
spec:
  restartPolicy: Never
  containers:
    - name: node
      image: node:22.17.1-bullseye
      command: ['cat']
      tty: true
    - name: kaniko
      image: gcr.io/kaniko-project/executor:debug
      command: ['/busybox/sh','-c','sleep infinity']
      tty: true
      volumeMounts:
        - name: docker-config
          mountPath: /kaniko/.docker
        - name: workspace
          mountPath: /workspace
  volumes:
    - name: workspace
      emptyDir: {}
    - name: docker-config
      secret:
        secretName: dockerhub-cred-front
        items:
          - key: .dockerconfigjson
            path: config.json
"""
    }
  }

  environment {
    IMAGE_NAME = 'bwuk072/front_demo'
    IMAGE_TAG = "${BUILD_NUMBER}"
  }

  stages {
    stage('Checkout') {
      steps {
        container('node') {
          echo "Cloning Repository"
          checkout([$class: 'GitSCM',
            branches: [[name: '*/main']],
            userRemoteConfigs: [[url: 'https://github.com/kbw07/DabomFront']]
          ])
        }
      }
    }

    stage('Node.js Build') {
      steps {
        container('node') {
          sh '''
            cd frontEnd
            npm i
            npm run build
          '''
        }
      }
    }

    stage('Build & Push Docker Image with Kaniko') {
      steps {
        container('kaniko') {
          echo "Building and pushing Docker image with Kaniko"
          cd frontEnd
          sh """
            /kaniko/executor \
              --context=${WORKSPACE} \
              --dockerfile=${WORKSPACE}/Dockerfile \
              --destination=${IMAGE_NAME}:${IMAGE_TAG} \
              --destination=${IMAGE_NAME}:latest \
              --single-snapshot \
              --use-new-run \
              --cache=true \
              --snapshotMode=redo
          """
        }
      }
    }

    stage('Deploy to Kubernetes') {
      steps {
        echo "Deploying to Kubernetes with Blue-Green strategy via SSH"
        script {
          sshPublisher(
            publishers: [
              sshPublisherDesc(
                configName: 'K8S_MASTER',
                verbose: true,
                transfers: [
                  sshTransfer(
                    execCommand: """
                      if kubectl get svc dabom-front -n dabom -o wide | grep -q "green"; then
                        CURRENT_VER="green"
                        NEXT_VER="blue"
                      else
                        CURRENT_VER="blue"
                        NEXT_VER="green"
                      fi

                      echo "Current version: \$CURRENT_VER, Next version: \$NEXT_VER"

                      cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vue-deployment-\${NEXT_VER}
  namespace: dabom
spec:
  selector:
    matchLabels:
      type: app
      ver: \${NEXT_VER}
  replicas: 1
  strategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        type: app
        ver: \${NEXT_VER}
    spec:
      containers:
      - name: container
        image: ${IMAGE_NAME}:${IMAGE_TAG}
        ports:
        - containerPort: 80
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 5
          successThreshold: 2
      terminationGracePeriodSeconds: 0
EOF

                      kubectl rollout status deployment/vue-deployment-\${NEXT_VER} -n dabom
                      kubectl patch service dabom-front -n dabom -p '{"spec":{"selector":{"ver":"'\${NEXT_VER}'"}}}'
                      kubectl scale deployment vue-deployment-\${CURRENT_VER} -n dabom --replicas=0

                      echo "Deployment completed successfully"
                    """
                  )
                ]
              )
            ]
          )
        }
      }
    }
  }
}