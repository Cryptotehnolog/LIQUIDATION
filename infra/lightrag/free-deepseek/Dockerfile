FROM node:22-alpine

ARG FREE_DEEPSEEK_REPO=https://github.com/ForgetMeAI/FreeDeepseekAPI.git
ARG FREE_DEEPSEEK_REF=e54d324e1d6be1f4d074f5c7f078ae5d94deade8

RUN apk add --no-cache git

RUN git clone --depth 1 --branch "$FREE_DEEPSEEK_REF" "$FREE_DEEPSEEK_REPO" /app

WORKDIR /app

RUN npm install --omit=dev

ENV HOST=0.0.0.0
ENV PORT=9655

EXPOSE 9655

CMD ["npm", "start"]
